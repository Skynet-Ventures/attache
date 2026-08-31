/**
 * A live, attached omp session: owns the `omp --mode rpc` process, keeps a
 * state snapshot, normalizes events for the app, and intercepts approvals.
 */

import { OmpProcess } from "../rpc/omp-process";
import { isApprovalSelect, parseApproval, RuleStore } from "../approvals";
import type {
	AdvisorNote,
	ApprovalRequest,
	PromptMode,
	RpcExtensionUIRequest,
	RpcFrame,
	SessionState,
	ServerEvent,
	ThinkingLevel,
	Verdict,
} from "../types";

const ADVISORY_RE =
	/<advisory(?:\s+advisor="([^"]*)")?(?:\s+severity="([^"]*)")?[^>]*>([\s\S]*?)<\/advisory>/g;

export type SessionEventSink = (event: ServerEvent) => void;

export class LiveSession {
	readonly id: string;
	readonly proc: OmpProcess;
	private readonly sinks = new Set<SessionEventSink>();
	private seq = 0;
	private turn = 0;
	private costUsd: number | null = null;
	private state: SessionState | null = null;
	private pendingApprovals = new Map<string, ApprovalRequest>();
	private textDeltaBuffer: { frame: Record<string, unknown>; timer: ReturnType<typeof setTimeout> } | null = null;
	onDispose: (() => void) | null = null;

	constructor(
		readonly cwd: string,
		private readonly rules: RuleStore,
		opts: { resume?: string; ompBin?: string } = {},
	) {
		this.id = crypto.randomUUID();
		this.proc = new OmpProcess({ cwd, resume: opts.resume, ompBin: opts.ompBin });
	}

	async start(): Promise<void> {
		await this.rules.load();
		this.proc.onExit = () => {
			this.emit({ type: "stream", sessionId: this.id, seq: ++this.seq, event: { type: "session_exited" } });
			this.onDispose?.();
		};
		await this.proc.start();
		this.proc.subscribe(frame => this.onFrame(frame));
		// Forward subagent lifecycle + full events so the hub screen is live.
		await this.proc.request({ type: "set_subagent_subscription", level: "events" }).catch(() => {});
		await this.refreshState();
	}

	subscribe(sink: SessionEventSink): () => void {
		this.sinks.add(sink);
		return () => this.sinks.delete(sink);
	}

	get snapshot(): SessionState | null {
		return this.state;
	}

	get approvals(): ApprovalRequest[] {
		return [...this.pendingApprovals.values()];
	}

	// -- commands ------------------------------------------------------------

	async prompt(
		message: string,
		mode: PromptMode = "chat",
		streamingBehavior?: "steer" | "followUp",
		images?: Array<{ data: string; mimeType: string }>,
	): Promise<void> {
		const text = mode === "chat" ? message : `/${mode} ${message}`;
		const res = await this.proc.request({
			type: "prompt",
			message: text,
			...(streamingBehavior ? { streamingBehavior } : {}),
			...(images && images.length > 0
				? { images: images.map(i => ({ type: "image", data: i.data, mimeType: i.mimeType })) }
				: {}),
		});
		if (!res.success) throw new Error(res.error ?? "prompt failed");
	}

	async steer(message: string): Promise<void> {
		const res = await this.proc.request({ type: "steer", message });
		if (!res.success) throw new Error(res.error ?? "steer failed");
	}

	async followUp(message: string): Promise<void> {
		const res = await this.proc.request({ type: "follow_up", message });
		if (!res.success) throw new Error(res.error ?? "follow_up failed");
	}

	async abort(): Promise<void> {
		const res = await this.proc.request({ type: "abort" });
		if (!res.success) throw new Error(res.error ?? "abort failed");
	}

	async setModel(provider: string, modelId: string): Promise<void> {
		const res = await this.proc.request({ type: "set_model", provider, modelId });
		if (!res.success) throw new Error(res.error ?? "set_model failed");
		await this.refreshState();
	}

	async setThinkingLevel(level: ThinkingLevel): Promise<void> {
		const res = await this.proc.request({ type: "set_thinking_level", level });
		if (!res.success) throw new Error(res.error ?? "set_thinking_level failed");
		await this.refreshState();
	}

	async branch(entryId: string): Promise<void> {
		const res = await this.proc.request({ type: "branch", entryId });
		if (!res.success) throw new Error(res.error ?? "branch failed");
	}

	async compact(): Promise<void> {
		const res = await this.proc.request({ type: "compact" }, 600_000);
		if (!res.success) throw new Error(res.error ?? "compact failed");
	}

	async getMessagesPage(cursor?: string, limit?: number): Promise<unknown> {
		const res = await this.proc.request({ type: "get_messages_page", cursor, limit });
		if (!res.success) throw new Error(res.error ?? "get_messages_page failed");
		return res.data;
	}

	/**
	 * Branchable entry points, read straight from the session jsonl (the RPC
	 * message APIs don't expose entry ids). Returns user-message entries,
	 * oldest first, each with a short preview for the branch sheet.
	 */
	async getEntries(): Promise<Array<{ id: string; role: string; preview: string; timestamp: string }>> {
		const file = this.state?.sessionFile;
		if (!file) return [];
		let text: string;
		try {
			text = await Bun.file(file).text();
		} catch {
			return [];
		}
		const out: Array<{ id: string; role: string; preview: string; timestamp: string }> = [];
		for (const line of text.split("\n")) {
			if (!line.includes('"type":"message"')) continue;
			try {
				const entry = JSON.parse(line) as {
					type?: string;
					id?: string;
					timestamp?: string;
					message?: { role?: string; content?: Array<{ type?: string; text?: string }> };
				};
				if (entry.type !== "message" || !entry.id) continue;
				const role = entry.message?.role ?? "";
				if (role !== "user" && role !== "assistant") continue;
				const textBlock = entry.message?.content?.find(b => b.type === "text" && b.text?.trim());
				if (!textBlock?.text) continue;
				out.push({
					id: entry.id,
					role,
					preview: textBlock.text.trim().slice(0, 80),
					timestamp: entry.timestamp ?? "",
				});
			} catch {
				/* torn line */
			}
		}
		return out;
	}

	async getSubagents(): Promise<unknown> {
		const res = await this.proc.request({ type: "get_subagents" });
		if (!res.success) throw new Error(res.error ?? "get_subagents failed");
		return res.data;
	}

	async getSubagentMessages(subagentId: string, fromByte?: number): Promise<unknown> {
		const res = await this.proc.request({ type: "get_subagent_messages", subagentId, fromByte });
		if (!res.success) throw new Error(res.error ?? "get_subagent_messages failed");
		return res.data;
	}

	async steerSubagent(subagentId: string, message: string): Promise<void> {
		// omp has no direct subagent-steer RPC; route via the primary agent so
		// it forwards through the hub. This is visible in the transcript by
		// design — steers are supposed to leave a trace.
		await this.steer(`[steer for subagent ${subagentId}] ${message}`);
	}

	async resolveApproval(approvalId: string, verdict: Verdict): Promise<void> {
		const approval = this.pendingApprovals.get(approvalId);
		if (!approval) throw new Error(`No pending approval ${approvalId}`);
		this.pendingApprovals.delete(approvalId);
		let ruleNote: string | undefined;
		if (verdict === "allow_always") {
			const rule = await this.rules.addFromApproval(approval);
			ruleNote = rule.note;
		}
		this.proc.write({
			type: "extension_ui_response",
			id: approvalId,
			value: verdict === "deny" ? "Deny" : "Approve",
		});
		this.emit({
			type: "approval_resolved",
			sessionId: this.id,
			approvalId,
			verdict,
			by: "app",
			...(ruleNote ? { ruleNote } : {}),
		});
	}

	async refreshState(): Promise<SessionState | null> {
		try {
			const res = await this.proc.request({ type: "get_state" });
			if (!res.success) return this.state;
			const d = res.data as Record<string, any>;
			this.state = {
				sessionId: this.id,
				sessionName: d.sessionName ?? "",
				sessionFile: d.sessionFile ?? "",
				cwd: this.cwd,
				model: d.model ?? { provider: "?", id: "?" },
				thinkingLevel: d.thinkingLevel ?? "off",
				isStreaming: !!d.isStreaming,
				isCompacting: !!d.isCompacting,
				contextUsage: d.contextUsage ?? null,
				costUsd: this.costUsd,
				turn: this.turn,
				messageCount: d.messageCount ?? 0,
				queuedMessageCount: d.queuedMessageCount ?? 0,
				approvalMode: null,
				todoPhases: d.todoPhases ?? [],
			};
			this.emit({ type: "session_state", state: this.state });
			return this.state;
		} catch {
			return this.state;
		}
	}

	dispose(): void {
		this.proc.dispose();
	}

	// -- frame handling ------------------------------------------------------

	private onFrame(frame: RpcFrame): void {
		switch (frame.type) {
			case "extension_ui_request": {
				const req = frame as RpcExtensionUIRequest;
				if (isApprovalSelect(req)) {
					this.handleApproval(req);
					return;
				}
				// Non-approval dialogs: cancel-with-default rather than hang the
				// agent; notify/setStatus flow through as stream events.
				if (req.method === "select" || req.method === "confirm" || req.method === "input" || req.method === "editor") {
					this.forward(frame);
					return;
				}
				this.forward(frame);
				return;
			}
			case "turn_start":
				this.turn += 1;
				this.forward(frame);
				return;
			case "agent_end":
			case "turn_end":
				this.forward(frame);
				void this.pollUsage();
				return;
			case "message_end":
			case "message_start":
				this.scanForAdvisory(frame);
				this.forward(frame);
				return;
			case "message_update":
				this.forwardCoalesced(frame);
				return;
			case "subagent_lifecycle":
			case "subagent_progress":
			case "subagent_event":
				this.emit({
					type: "subagent",
					sessionId: this.id,
					kind: frame.type.replace("subagent_", ""),
					frame: frame as Record<string, unknown>,
				});
				return;
			case "model_changed":
			case "thinking_level_changed":
				this.forward(frame);
				void this.refreshState();
				return;
			case "ready":
			case "response":
				return; // correlated separately
			default:
				this.forward(frame as Record<string, unknown>);
		}
	}

	private handleApproval(req: RpcExtensionUIRequest): void {
		const approval = parseApproval(this.id, req);
		const rule = this.rules.match(approval);
		if (rule) {
			this.proc.write({ type: "extension_ui_response", id: req.id, value: "Approve" });
			this.emit({
				type: "approval_resolved",
				sessionId: this.id,
				approvalId: approval.id,
				verdict: "allow",
				by: "rule",
				ruleNote: rule.note,
			});
			return;
		}
		this.pendingApprovals.set(approval.id, approval);
		this.emit({ type: "approval_request", approval });
	}

	private scanForAdvisory(frame: Record<string, unknown>): void {
		const message = frame.message as { content?: Array<{ type?: string; text?: string }> } | undefined;
		if (!message?.content) return;
		for (const block of message.content) {
			if (typeof block?.text !== "string" || !block.text.includes("<advisory")) continue;
			for (const match of block.text.matchAll(ADVISORY_RE)) {
				const note: AdvisorNote = {
					sessionId: this.id,
					advisor: match[1] || "advisor",
					severity: (match[2] as AdvisorNote["severity"]) || "concern",
					text: (match[3] ?? "").trim(),
					timestamp: new Date().toISOString(),
				};
				this.emit({ type: "advisor", note });
			}
		}
	}

	private async pollUsage(): Promise<void> {
		try {
			const res = await this.proc.request({ type: "get_session_stats" });
			if (res.success && res.data && typeof res.data === "object") {
				const d = res.data as Record<string, any>;
				const cost = d.costUsd ?? d.cost ?? d.totalCost ?? d.usage?.cost;
				if (typeof cost === "number") this.costUsd = cost;
			}
		} catch {
			/* stats are best-effort */
		}
		await this.refreshState();
	}

	/** Coalesce high-frequency text deltas to ~30fps per session. */
	private forwardCoalesced(frame: Record<string, unknown>): void {
		const ev = frame.assistantMessageEvent as { type?: string; delta?: string } | undefined;
		if (ev?.type !== "text_delta" && ev?.type !== "thinking_delta") {
			this.flushDeltas();
			this.forward(frame);
			return;
		}
		if (this.textDeltaBuffer && (this.textDeltaBuffer.frame.assistantMessageEvent as any)?.type === ev.type) {
			(this.textDeltaBuffer.frame.assistantMessageEvent as any).delta += ev.delta ?? "";
			this.textDeltaBuffer.frame.message = frame.message;
			return;
		}
		this.flushDeltas();
		const copy = { ...frame, assistantMessageEvent: { ...ev } };
		this.textDeltaBuffer = {
			frame: copy,
			timer: setTimeout(() => this.flushDeltas(), 33),
		};
	}

	private flushDeltas(): void {
		if (!this.textDeltaBuffer) return;
		clearTimeout(this.textDeltaBuffer.timer);
		const f = this.textDeltaBuffer.frame;
		this.textDeltaBuffer = null;
		this.forward(f);
	}

	private forward(event: Record<string, unknown>): void {
		this.emit({ type: "stream", sessionId: this.id, seq: ++this.seq, event });
	}

	private emit(event: ServerEvent): void {
		for (const sink of this.sinks) {
			try {
				sink(event);
			} catch (err) {
				console.error("[live-session] sink error", err);
			}
		}
	}
}
