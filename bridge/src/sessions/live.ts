/**
 * A live, attached omp session: owns the `omp --mode rpc` process, keeps a
 * state snapshot, normalizes events for the app, and intercepts approvals.
 */

import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { OmpProcess } from "../rpc/omp-process";
import { readSessionEntries } from "./store";
import { isApprovalSelect, parseApproval, RuleStore } from "../approvals";
import { ApprovalTimer } from "../approval-timer";
import { getApprovalMode } from "../config";
import { drainMessages, MESSAGES_PAGE_LIMIT, type DrainOverrides, type MessagesPageResult } from "../messages";
import { ProtocolError } from "../errors";
import type {
	AdvisorNote,
	ApprovalMode,
	ApprovalRequest,
	PromptMode,
	RpcExtensionUIRequest,
	RpcFrame,
	RpcResponseFrame,
	SessionState,
	ServerEvent,
	SteeringMode,
	InterruptMode,
	ThinkingLevel,
	Verdict,
} from "../types";

/**
 * Cap individual text blocks in history payloads. Tool results (build logs,
 * test output) can run to hundreds of KB per message; the app renders only an
 * excerpt, and an untrimmed full-transcript frame can blow past the client's
 * websocket message-size limit — which surfaces as a transcript that never
 * loads. Live streaming events are not trimmed, only history reads.
 */
const WIRE_TEXT_CAP = 32_768;

export function trimMessageForWire(entry: unknown): unknown {
	const e = entry as { message?: { content?: unknown[] } };
	const content = e?.message?.content;
	if (!Array.isArray(content)) return entry;
	let changed = false;
	const trimmed = content.map(block => {
		const b = block as { text?: unknown };
		if (typeof b?.text !== "string" || b.text.length <= WIRE_TEXT_CAP) return block;
		changed = true;
		const dropped = b.text.length - WIRE_TEXT_CAP;
		return { ...(block as object), text: `${b.text.slice(0, WIRE_TEXT_CAP)}\n… [${dropped} chars truncated for transport]` };
	});
	if (!changed) return entry;
	return { ...(entry as object), message: { ...e.message, content: trimmed } };
}

/**
 * The subset of OmpProcess the session uses — injectable in tests so the
 * session's approval/forwarding behavior can be exercised with a stub.
 */
export interface SessionProc {
	onExit: ((code: number) => void) | null;
	start(): Promise<void>;
	subscribe(listener: (frame: RpcFrame) => void): () => void;
	request(command: Record<string, unknown>, timeoutMs?: number): Promise<RpcResponseFrame>;
	write(frame: Record<string, unknown>): void;
	dispose(): void;
	kill(): void;
}

const ADVISORY_RE =
	/<advisory(?:\s+advisor="([^"]*)")?(?:\s+severity="([^"]*)")?[^>]*>([\s\S]*?)<\/advisory>/g;

/** Validate an inbound queue-mode value; unknown values fall back to the omp default. */
function normalizeSteeringMode(v: unknown): SteeringMode {
	return v === "all" || v === "one-at-a-time" ? v : "one-at-a-time";
}

/** Validate an inbound interrupt-mode value; unknown values fall back to the omp default. */
function normalizeInterruptMode(v: unknown): InterruptMode {
	return v === "immediate" || v === "wait" ? v : "immediate";
}

export type SessionEventSink = (event: ServerEvent) => void;

export class LiveSession {
	readonly id: string;
	readonly proc: SessionProc;
	private readonly sinks = new Set<SessionEventSink>();
	private seq = 0;
	private turn = 0;
	private costUsd: number | null = null;
	private state: SessionState | null = null;
	private pendingApprovals = new Map<string, ApprovalRequest>();
	private approvalModeOverride: ApprovalMode | null = null;
	private approvalTimers: ApprovalTimer;
	private textDeltaBuffer: { frame: Record<string, unknown>; timer: ReturnType<typeof setTimeout> } | null = null;
	onDispose: (() => void) | null = null;

	constructor(
		readonly cwd: string,
		private readonly rules: RuleStore,
		opts: { resume?: string; ompBin?: string; proc?: SessionProc; approvalTimeoutMs?: number } = {},
	) {
		this.id = crypto.randomUUID();
		this.proc = opts.proc ?? new OmpProcess({ cwd, resume: opts.resume, ompBin: opts.ompBin });
		this.approvalTimers = new ApprovalTimer(opts.approvalTimeoutMs ?? 0, approvalId =>
			this.timeoutApproval(approvalId),
		);
	}

	/** Immediately kill the underlying omp process (orphan cleanup). */
	kill(): void {
		this.proc.kill();
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

	/** omp `handoff` passthrough; returns omp's result data verbatim. */
	async handoff(instructions?: string): Promise<unknown> {
		const res = await this.proc.request({
			type: "handoff",
			...(instructions ? { customInstructions: instructions } : {}),
		});
		if (!res.success) throw new Error(res.error ?? "handoff failed");
		return res.data;
	}

	/**
	 * Set per-session queue/interrupt modes via omp's set_*_mode RPCs. Only
	 * the modes provided are sent; the result echoes the final computed modes
	 * (requested values over the current session state).
	 */
	async setQueueModes(opts: {
		steeringMode?: SteeringMode;
		followUpMode?: SteeringMode;
		interruptMode?: InterruptMode;
	}): Promise<{ steeringMode: SteeringMode; followUpMode: SteeringMode; interruptMode: InterruptMode }> {
		if (opts.steeringMode) {
			const res = await this.proc.request({ type: "set_steering_mode", mode: opts.steeringMode });
			if (!res.success) throw new Error(res.error ?? "set_steering_mode failed");
		}
		if (opts.followUpMode) {
			const res = await this.proc.request({ type: "set_follow_up_mode", mode: opts.followUpMode });
			if (!res.success) throw new Error(res.error ?? "set_follow_up_mode failed");
		}
		if (opts.interruptMode) {
			const res = await this.proc.request({ type: "set_interrupt_mode", mode: opts.interruptMode });
			if (!res.success) throw new Error(res.error ?? "set_interrupt_mode failed");
		}
		const current = this.state;
		const finalModes = {
			steeringMode: opts.steeringMode ?? current?.steeringMode ?? "one-at-a-time",
			followUpMode: opts.followUpMode ?? current?.followUpMode ?? "one-at-a-time",
			interruptMode: opts.interruptMode ?? current?.interruptMode ?? "immediate",
		};
		await this.refreshState();
		return finalModes;
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

	/**
	 * Ask omp to export the transcript HTML to a temp file, then read it back
	 * base64-encoded. Files over the 20MB cap surface a `too_large` error so
	 * the app can offer the raw file instead.
	 */
	async exportHtml(): Promise<{ html: string }> {
		const exportDir = await mkdtemp(join(tmpdir(), "attache-export-"));
		const outputPath = join(exportDir, "session.html");
		const CAP = 20 * 1024 * 1024;
		try {
			const res = await this.proc.request({ type: "export_html", outputPath }, 600_000);
			if (!res.success) throw new Error(res.error ?? "export_html failed");
			const size = (await stat(outputPath)).size;
			if (size > CAP) {
				throw new ProtocolError("too_large", `exported html is ${size} bytes (20MB cap)`);
			}
			return { html: (await readFile(outputPath)).toString("base64") };
		} finally {
			await rm(exportDir, { recursive: true, force: true });
		}
	}

	/**
	 * Drain every page of omp's `get_messages_page` for the full transcript.
	 * `session_busy` is retried with backoff (≤~10s) then surfaced as a
	 * `session_busy` result; a `stale_cursor` restarts the walk once from the
	 * start and surfaces `stale_cursor` if it recurs.
	 *
	 * `overrides` is a test seam for the backoff/sleep policy (see
	 * drainMessages) — the wire dispatch never sets it.
	 */
	async getMessages(
		inputCursor?: string,
		limit?: number,
		overrides: DrainOverrides = {},
	): Promise<{ messages: unknown[]; totalMessages: number }> {
		const fetchPage = async (cursor: string | undefined, pageLimit: number): Promise<MessagesPageResult> => {
			const res = await this.proc.request({
				type: "get_messages_page",
				cursor,
				limit: limit ?? pageLimit,
			});
			if (!res.success) {
				if (res.code === "session_busy" || res.code === "stale_cursor") {
					return { ok: false, error: res.code };
				}
				throw new Error(res.error ?? "get_messages_page failed");
			}
			const data = (res.data ?? {}) as { messages?: unknown[]; totalMessages?: number; nextCursor?: string };
			if (!Array.isArray(data.messages)) throw new Error("get_messages_page returned no messages");
			return { ok: true, messages: data.messages, totalMessages: data.totalMessages, nextCursor: data.nextCursor };
		};
		const result = await drainMessages({ fetchPage, startCursor: inputCursor, ...overrides });
		if (!result.ok) throw new ProtocolError(result.error, `history unavailable: ${result.error}`);
		return { messages: result.messages.map(trimMessageForWire), totalMessages: result.totalMessages };
	}

	/**
	 * Branchable entry points, read straight from the session jsonl (the RPC
	 * message APIs don't expose entry ids). Returns user-message entries,
	 * oldest first, each with a short preview for the branch sheet.
	 */
	async getEntries(): Promise<Array<{ id: string; role: string; preview: string; timestamp: string }>> {
		const file = this.state?.sessionFile;
		if (!file) return [];
		return readSessionEntries(file);
	}

	/**
	 * Read the transcript straight from the session jsonl. The RPC history
	 * pager refuses to run while the session is streaming (session_busy), but
	 * the on-disk file is always readable — this keeps a freshly attached
	 * client from staring at a blank transcript through a long turn.
	 *
	 * The jsonl is an append-only tree (entries carry `parentId`); after a
	 * `branch`, abandoned-branch entries stay in the file. A linear scan
	 * would interleave them into the transcript, so walk the parent chain up
	 * from the newest entry (the live leaf) and render only that path.
	 */
	async readTranscriptFromDisk(maxMessages = 600): Promise<{ messages: unknown[]; fromDisk: true }> {
		const file = this.state?.sessionFile;
		if (!file) return { messages: [], fromDisk: true };
		let text: string;
		try {
			text = await Bun.file(file).text();
		} catch {
			return { messages: [], fromDisk: true };
		}
		type DiskEntry = { type?: string; id?: string; parentId?: string | null; message?: unknown };
		const byId = new Map<string, DiskEntry>();
		let leaf: DiskEntry | null = null;
		for (const line of text.split("\n")) {
			if (!line.trim()) continue;
			try {
				const entry = JSON.parse(line) as DiskEntry;
				if (!entry.id) continue;
				byId.set(entry.id, entry);
				leaf = entry; // last parseable entry = live leaf while streaming
			} catch {
				/* torn tail line mid-write — expected while streaming */
			}
		}
		const messages: unknown[] = [];
		for (let cur = leaf; cur; cur = cur.parentId ? (byId.get(cur.parentId) ?? null) : null) {
			if (cur.type === "message" && cur.message) {
				messages.push(trimMessageForWire({ id: cur.id, message: cur.message }));
			}
			if (messages.length >= maxMessages) break;
		}
		messages.reverse();
		return { messages, fromDisk: true };
	}

	/**
	 * Write an uploaded file into the session's working directory so the
	 * agent can read it. Files land in <cwd>/attache-uploads/.
	 */
	async saveUpload(name: string, base64: string): Promise<string> {
		const { mkdir, writeFile } = await import("node:fs/promises");
		const { join, basename } = await import("node:path");
		const safeName = basename(name).replace(/[^\w.\-]/g, "_").slice(0, 120) || "upload";
		const bytes = Buffer.from(base64, "base64");
		if (bytes.byteLength > 25 * 1024 * 1024) throw new Error("file too large (25MB max)");
		const dir = join(this.cwd, "attache-uploads");
		await mkdir(dir, { recursive: true });
		let target = join(dir, safeName);
		try {
			// Don't clobber an existing upload with the same name.
			const { stat } = await import("node:fs/promises");
			await stat(target);
			target = join(dir, `${Date.now()}-${safeName}`);
		} catch {
			/* free */
		}
		await writeFile(target, bytes);
		return target;
	}

	async getSubagents(): Promise<unknown> {
		const res = await this.proc.request({ type: "get_subagents" });
		if (!res.success) throw new Error(res.error ?? "get_subagents failed");
		return this.enrichSubagents(res.data);
	}

	/** Session artifacts directory (sibling dir named after the jsonl stem). */
	private artifactsDir(): string | null {
		const file = this.state?.sessionFile;
		if (!file || !file.endsWith(".jsonl")) return null;
		return file.slice(0, -".jsonl".length);
	}

	/**
	 * Attach disk-derived extras to omp's registry snapshot: whether an
	 * isolated run left a reviewable `<id>.patch`, plus any worktree/branch
	 * metadata omp included. Unknown shapes pass through untouched.
	 */
	private async enrichSubagents(data: unknown): Promise<unknown> {
		const dir = this.artifactsDir();
		const list = Array.isArray(data)
			? data
			: (data as { subagents?: unknown[] })?.subagents;
		if (!dir || !Array.isArray(list)) return data;
		const { stat } = await import("node:fs/promises");
		const { join, basename } = await import("node:path");
		for (const entry of list as Array<Record<string, unknown>>) {
			const id = String(entry.id ?? entry.subagentId ?? entry.name ?? "");
			if (!id) continue;
			const safe = basename(id);
			try {
				const s = await stat(join(dir, `${safe}.patch`));
				if (s.size > 0) {
					entry.hasPatch = true;
					entry.patchBytes = s.size;
				}
			} catch {
				/* no patch artifact — not isolated or branch-mode merge */
			}
		}
		return data;
	}

	/** Contents of an isolated subagent's captured patch, for diff review. */
	async getSubagentPatch(subagentId: string): Promise<{ patch: string; bytes: number }> {
		const dir = this.artifactsDir();
		if (!dir) throw new Error("session file unknown");
		const { basename, join } = await import("node:path");
		const path = join(dir, `${basename(subagentId)}.patch`);
		const file = Bun.file(path);
		if (!(await file.exists())) throw new Error(`no patch artifact for ${subagentId}`);
		if (file.size > 4 * 1024 * 1024) {
			const text = await file.text();
			return { patch: `${text.slice(0, 4 * 1024 * 1024)}\n… (truncated)`, bytes: file.size };
		}
		return { patch: await file.text(), bytes: file.size };
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

	async resolveApproval(approvalId: string, verdict: Verdict, scope?: unknown): Promise<void> {
		const approval = this.pendingApprovals.get(approvalId);
		if (!approval) throw new Error(`No pending approval ${approvalId}`);
		this.pendingApprovals.delete(approvalId);
		this.approvalTimers.cancel(approvalId);
		let ruleNote: string | undefined;
		if (verdict === "allow_always") {
			const rule = await this.rules.addFromApproval(approval, scope);
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
			const approvalMode = this.approvalModeOverride ?? (await getApprovalMode().catch(() => null));
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
				approvalMode,
				fastModeEnabled: !!d.fastModeEnabled,
				fastModeActive: !!d.fastModeActive,
				steeringMode: normalizeSteeringMode(d.steeringMode),
				followUpMode: normalizeSteeringMode(d.followUpMode),
				interruptMode: normalizeInterruptMode(d.interruptMode),
				todoPhases: d.todoPhases ?? [],
			};
			this.emit({ type: "session_state", state: this.state });
			return this.state;
		} catch {
			return this.state;
		}
	}

	/**
	 * Store a per-session approval-mode override (applied to bridge-side
	 * auto-approval and reported in session_state). Omit to fall back to the
	 * global config value.
	 */
	setApprovalModeOverride(mode: ApprovalMode | null): void {
		this.approvalModeOverride = mode;
		void this.refreshState();
	}

	async setSessionName(name: string): Promise<void> {
		const res = await this.proc.request({ type: "set_session_name", name });
		if (!res.success) throw new Error(res.error ?? "set_session_name failed");
		await this.refreshState();
	}

	async getSessionStats(): Promise<unknown> {
		const res = await this.proc.request({ type: "get_session_stats" });
		if (!res.success) throw new Error(res.error ?? "get_session_stats failed");
		return res.data;
	}

	/** Toggle omp fast mode; reports the computed { enabled, active } state. */
	async setFastMode(enabled: boolean): Promise<{ enabled: boolean; active: boolean }> {
		const res = await this.proc.request({ type: "set_fast_mode", enabled });
		if (res.success && res.data !== undefined && res.data !== null && typeof res.data === "object") {
			const d = res.data as { enabled?: unknown; active?: unknown };
			await this.refreshState();
			return { enabled: Boolean(d.enabled), active: Boolean(d.active) };
		}
		// Unsupported model: omp rejects with success:false. Report the intent
		// with a non-active result; get_state carries the authoritative state.
		await this.refreshState();
		return { enabled, active: false };
	}

	dispose(): void {
		this.approvalTimers.clear();
		this.flushDeltas();
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
				// All other extension UI requests are forwarded verbatim. The app
				// answers via `ui_response`, or omp cancels on its own timeout —
				// the bridge does not auto-resolve non-approval dialogs.
				this.forward(frame);
				return;
			}
			case "available_commands_update": {
				const commands = "commands" in frame ? frame.commands : undefined;
				this.emit({ type: "commands", sessionId: this.id, commands });
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
		const rule = this.rules.match(approval, { cwd: this.cwd });
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
		// Per-session yolo mode auto-approves anything the agent still asks
		// about (omp normally suppresses approvals in yolo; this is the
		// belt-and-suspenders path when it does not).
		if (this.approvalModeOverride === "yolo") {
			this.proc.write({ type: "extension_ui_response", id: req.id, value: "Approve" });
			this.emit({
				type: "approval_resolved",
				sessionId: this.id,
				approvalId: approval.id,
				verdict: "allow",
				by: "mode",
			});
			return;
		}
		this.pendingApprovals.set(approval.id, approval);
		this.approvalTimers.start(approval.id);
		this.emit({ type: "approval_request", approval });
	}

	/** Expired pending approval: answer omp with Deny and report the timeout. */
	private timeoutApproval(approvalId: string): void {
		const approval = this.pendingApprovals.get(approvalId);
		if (!approval) return; // resolved concurrently
		this.pendingApprovals.delete(approvalId);
		this.proc.write({ type: "extension_ui_response", id: approvalId, value: "Deny" });
		this.emit({
			type: "approval_resolved",
			sessionId: this.id,
			approvalId,
			verdict: "deny",
			by: "timeout",
		});
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
