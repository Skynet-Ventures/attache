/**
 * HTTP + WebSocket server: pairing, health, and the app protocol
 * (docs/protocol.md).
 */

import { hostname } from "node:os";
import type { ServerWebSocket } from "bun";
import { Auth } from "./auth";
import { RuleStore } from "./approvals";
import { ProjectStore } from "./projects";
import { Push } from "./push";
import { LiveSession } from "./sessions/live";
import { groupByProject, listStoredSessions, searchStoredSessions } from "./sessions/store";
import { getApprovalMode, getEnabledModels, getRoles, setApprovalModeGlobal, setRole } from "./config";
import {
	PROTOCOL_VERSION,
	type ClientCommand,
	type MachineInfo,
	type ServerEvent,
	type SessionSummary,
	type Verdict,
} from "./types";

const BRIDGE_VERSION = "0.1.0";

interface SocketData {
	deviceId: string;
	deviceName: string;
	attached: Map<string, () => void>; // sessionId -> unsubscribe
}

type WS = ServerWebSocket<SocketData>;

export interface ServeOptions {
	port: number;
	host: string;
	ompBin?: string;
}

export class BridgeServer {
	readonly auth = new Auth();
	readonly rules = new RuleStore();
	readonly push = new Push();
	readonly projects = new ProjectStore();
	private readonly sessions = new Map<string, LiveSession>();
	private readonly sockets = new Set<WS>();
	private readonly startedAt = Date.now();
	private ompVersion = "unknown";

	constructor(private readonly opts: ServeOptions) {}

	async start(): Promise<{ url: string; code: string }> {
		await Promise.all([this.auth.load(), this.rules.load(), this.push.load(), this.projects.load()]);
		try {
			const proc = Bun.spawn([this.opts.ompBin ?? "omp", "--version"], { stdout: "pipe" });
			this.ompVersion = (await new Response(proc.stdout).text()).trim().split("\n")[0] ?? "unknown";
		} catch {
			console.warn("[bridge] `omp` not found on PATH — live sessions will fail to start");
		}

		const server = Bun.serve<SocketData>({
			port: this.opts.port,
			hostname: this.opts.host,
			fetch: (req, srv) => this.fetch(req, srv),
			websocket: {
				open: ws => this.onOpen(ws),
				message: (ws, message) => void this.onMessage(ws, message),
				close: ws => this.onClose(ws),
				sendPings: true,
				idleTimeout: 120,
			},
		});

		const code = this.auth.issueCode();
		return { url: `http://${server.hostname}:${server.port}`, code };
	}

	// ---------------------------------------------------------------- HTTP --

	private async fetch(req: Request, srv: Bun.Server<SocketData>): Promise<Response | undefined> {
		const url = new URL(req.url);
		if (url.pathname === "/health") {
			return Response.json({
				ok: true,
				name: "attache-bridge",
				version: BRIDGE_VERSION,
				ompVersion: this.ompVersion,
			});
		}
		if (url.pathname === "/pair" && req.method === "POST") {
			const body = (await req.json().catch(() => ({}))) as { code?: string; deviceName?: string };
			const token = await this.auth.redeemCode(body.code ?? "", body.deviceName ?? "iOS device");
			if (!token) return Response.json({ error: "invalid or expired code" }, { status: 403 });
			console.log(`[bridge] paired device "${body.deviceName ?? "iOS device"}"`);
			return Response.json({ token, machine: this.machineInfo() });
		}
		if (url.pathname === "/verdict" && req.method === "POST") {
			const body = (await req.json().catch(() => ({}))) as {
				token?: string;
				sessionId?: string;
				approvalId?: string;
				verdict?: Verdict;
			};
			const device = await this.auth.verify(body.token);
			if (!device) return Response.json({ error: "unauthorized" }, { status: 401 });
			const session = body.sessionId ? this.sessions.get(body.sessionId) : this.findSessionByApproval(body.approvalId);
			if (!session || !body.approvalId || !body.verdict) {
				return Response.json({ error: "unknown approval" }, { status: 404 });
			}
			await session.resolveApproval(body.approvalId, body.verdict);
			return Response.json({ ok: true });
		}
		if (url.pathname === "/ws") {
			const token =
				req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? url.searchParams.get("token");
			const device = await this.auth.verify(token);
			if (!device) return new Response("unauthorized", { status: 401 });
			const ok = srv.upgrade(req, {
				data: {
					deviceId: device.id,
					deviceName: device.name,
					attached: new Map(),
				} satisfies SocketData,
			});
			return ok ? undefined : new Response("upgrade failed", { status: 400 });
		}
		return new Response("attache-bridge", { status: 404 });
	}

	// ----------------------------------------------------------- WebSocket --

	private onOpen(ws: WS): void {
		this.sockets.add(ws);
		this.sendEvent(ws, { type: "machine_info", machine: this.machineInfo() });
	}

	private onClose(ws: WS): void {
		for (const [, unsubscribe] of ws.data.attached) unsubscribe();
		ws.data.attached.clear();
		this.sockets.delete(ws);
	}

	private async onMessage(ws: WS, message: string | Buffer): Promise<void> {
		let cmd: ClientCommand;
		try {
			cmd = JSON.parse(String(message)) as ClientCommand;
		} catch {
			this.sendEvent(ws, { type: "result", ok: false, error: "malformed json" });
			return;
		}
		try {
			const data = await this.dispatch(ws, cmd);
			this.sendEvent(ws, { type: "result", id: cmd.id, ok: true, ...(data === undefined ? {} : { data }) });
		} catch (err) {
			this.sendEvent(ws, {
				type: "result",
				id: cmd.id,
				ok: false,
				error: err instanceof Error ? err.message : String(err),
			});
		}
	}

	private async dispatch(ws: WS, cmd: ClientCommand): Promise<unknown> {
		switch (cmd.type) {
			case "hello":
				return {
					protocolVersion: PROTOCOL_VERSION,
					machine: this.machineInfo(),
					roles: await getRoles().catch(() => []),
					approvalMode: await getApprovalMode().catch(() => null),
					enabledModels: await getEnabledModels().catch(() => []),
				};

			case "list_sessions": {
				const stored = await listStoredSessions();
				const liveByPath = new Map<string, LiveSession>();
				for (const s of this.sessions.values()) {
					const file = s.snapshot?.sessionFile;
					if (file) liveByPath.set(file, s);
				}
				const summaries: SessionSummary[] = stored.map(s => {
					const live = liveByPath.get(s.sessionPath);
					if (!live) return s;
					const streaming = live.snapshot?.isStreaming ?? false;
					const waiting = live.approvals.length > 0;
					return {
						...s,
						id: live.id,
						live: true,
						status: waiting ? "waiting" : streaming ? "running" : "idle",
					};
				});
				// Live sessions whose file isn't in the stored scan yet (brand new).
				for (const s of this.sessions.values()) {
					const file = s.snapshot?.sessionFile;
					if (file && summaries.some(x => x.sessionPath === file)) continue;
					summaries.unshift({
						id: s.id,
						title: s.snapshot?.sessionName || "New session",
						project: s.cwd.split("/").pop() ?? s.cwd,
						cwd: s.cwd,
						sessionPath: file ?? "",
						updatedAt: new Date().toISOString(),
						live: true,
						status: s.approvals.length > 0 ? "waiting" : s.snapshot?.isStreaming ? "running" : "idle",
						shortId: `#${s.id.slice(0, 4)}`,
					});
				}
				return { projects: groupByProject(summaries, this.projects.list()) };
			}

			case "create_project": {
				const project = await this.projects.create(
					String(cmd.name ?? ""),
					Array.isArray(cmd.cwds) ? (cmd.cwds as string[]) : [],
				);
				this.broadcast({ type: "sessions_changed" });
				return { project };
			}
			case "rename_project": {
				const project = await this.projects.rename(String(cmd.projectId), String(cmd.name ?? ""));
				this.broadcast({ type: "sessions_changed" });
				return { project };
			}
			case "delete_project": {
				const removed = await this.projects.remove(String(cmd.projectId));
				this.broadcast({ type: "sessions_changed" });
				return { removed };
			}
			case "assign_cwd": {
				await this.projects.assignCwd(
					String(cmd.cwd ?? ""),
					cmd.projectId == null ? null : String(cmd.projectId),
				);
				this.broadcast({ type: "sessions_changed" });
				return {};
			}

			case "search_sessions":
				return { sessions: await searchStoredSessions(String(cmd.query ?? "")) };

			case "attach": {
				const existingId = typeof cmd.sessionId === "string" ? cmd.sessionId : null;
				let session = existingId ? this.sessions.get(existingId) : undefined;
				if (!session) {
					const resume =
						typeof cmd.sessionPath === "string"
							? cmd.sessionPath
							: existingId?.startsWith("stored:")
								? existingId.slice("stored:".length)
								: undefined;
					const cwd = typeof cmd.cwd === "string" ? cmd.cwd : process.env.HOME ?? "/";
					session = new LiveSession(cwd, this.rules, { resume, ompBin: this.opts.ompBin });
					const s = session;
					session.onDispose = () => {
						this.sessions.delete(s.id);
						this.broadcast({ type: "sessions_changed" });
					};
					await session.start();
					this.sessions.set(session.id, session);
					this.broadcast({ type: "sessions_changed" });
				}
				this.attachSocket(ws, session);
				// Push current pending approvals + state to the newly attached socket.
				const snap = session.snapshot;
				if (snap) this.sendEvent(ws, { type: "session_state", state: snap });
				for (const approval of session.approvals) {
					this.sendEvent(ws, { type: "approval_request", approval });
				}
				return { sessionId: session.id };
			}

			case "detach": {
				const id = String(cmd.sessionId ?? "");
				ws.data.attached.get(id)?.();
				ws.data.attached.delete(id);
				return {};
			}

			case "kill_session": {
				const session = this.requireSession(cmd);
				session.dispose();
				this.sessions.delete(session.id);
				this.broadcast({ type: "sessions_changed" });
				return {};
			}

			case "prompt": {
				const session = this.requireSession(cmd);
				await session.prompt(
					String(cmd.message ?? ""),
					(cmd.mode as never) ?? "chat",
					cmd.streamingBehavior as never,
					Array.isArray(cmd.images) ? (cmd.images as Array<{ data: string; mimeType: string }>) : undefined,
				);
				return {};
			}
			case "steer":
				await this.requireSession(cmd).steer(String(cmd.message ?? ""));
				return {};
			case "follow_up":
				await this.requireSession(cmd).followUp(String(cmd.message ?? ""));
				return {};
			case "abort":
				await this.requireSession(cmd).abort();
				return {};

			case "approval_verdict": {
				const session = this.requireSession(cmd);
				await session.resolveApproval(String(cmd.approvalId), cmd.verdict as Verdict);
				return {};
			}

			case "ui_response": {
				// Generic extension-dialog passthrough (non-approval select/input).
				const session = this.requireSession(cmd);
				session.proc.write({
					type: "extension_ui_response",
					id: String(cmd.requestId),
					...(cmd.value !== undefined ? { value: cmd.value } : {}),
					...(cmd.confirmed !== undefined ? { confirmed: cmd.confirmed } : {}),
					...(cmd.cancelled ? { cancelled: true } : {}),
				});
				return {};
			}

			case "get_messages":
				return this.requireSession(cmd).getMessagesPage(
					cmd.cursor as string | undefined,
					cmd.limit as number | undefined,
				);
			case "get_subagents":
				return this.requireSession(cmd).getSubagents();
			case "get_subagent_messages":
				return this.requireSession(cmd).getSubagentMessages(
					String(cmd.subagentId),
					cmd.fromByte as number | undefined,
				);
			case "steer_subagent":
				await this.requireSession(cmd).steerSubagent(String(cmd.subagentId), String(cmd.message ?? ""));
				return {};

			case "set_model":
				await this.requireSession(cmd).setModel(String(cmd.provider), String(cmd.modelId));
				return {};
			case "set_thinking_level":
				await this.requireSession(cmd).setThinkingLevel(cmd.level as never);
				return {};
			case "branch":
				await this.requireSession(cmd).branch(String(cmd.entryId));
				return {};
			case "get_entries":
				return { entries: await this.requireSession(cmd).getEntries() };
			case "compact":
				await this.requireSession(cmd).compact();
				return {};

			case "get_roles":
				return { roles: await getRoles() };
			case "set_role":
				return {
					roles: await setRole(
						String(cmd.role),
						cmd.model as string | undefined,
						cmd.thinkingLevel as never,
					),
				};
			case "set_approval_mode":
				await setApprovalModeGlobal(cmd.mode as never);
				return {};

			case "list_rules":
				return { rules: this.rules.list() };
			case "delete_rule":
				return { removed: await this.rules.remove(String(cmd.ruleId)) };

			case "register_push":
				await this.push.register({
					deviceId: ws.data.deviceId,
					transport: cmd.transport as "webhook" | "apns",
					target: String(cmd.target ?? ""),
				});
				return { registered: !!String(cmd.target ?? "").trim() };

			case "test_push": {
				if (!this.push.targetFor(ws.data.deviceId)) {
					throw new Error("no push target registered for this device");
				}
				await this.push.send(
					{
						kind: "turn_done",
						title: "Attaché test",
						body: `Push from ${this.machineInfo().name} works — you'll get approvals here when no device is connected.`,
						sessionId: "test",
					},
					ws.data.deviceId,
				);
				return {};
			}

			default:
				throw new Error(`unknown command: ${cmd.type}`);
		}
	}

	// -------------------------------------------------------------- helpers --

	private attachSocket(ws: WS, session: LiveSession): void {
		if (ws.data.attached.has(session.id)) return;
		const unsubscribe = session.subscribe(event => {
			this.sendEvent(ws, event);
			this.maybePush(event);
		});
		ws.data.attached.set(session.id, unsubscribe);
	}

	private lastPushAt = 0;

	private maybePush(event: ServerEvent): void {
		// Only push when nobody is connected to see it live.
		if (this.sockets.size > 0) return;
		if (event.type === "approval_request") {
			void this.push.send({
				kind: "approval",
				title: `Approval: ${event.approval.tool}`,
				body: event.approval.command ?? event.approval.prompt,
				sessionId: event.approval.sessionId,
				approvalId: event.approval.id,
			});
		} else if (event.type === "stream" && event.event.type === "agent_end") {
			const now = Date.now();
			if (now - this.lastPushAt < 30_000) return;
			this.lastPushAt = now;
			void this.push.send({
				kind: "turn_done",
				title: "omp finished a turn",
				body: "The agent is waiting for you.",
				sessionId: event.sessionId,
			});
		}
	}

	private requireSession(cmd: ClientCommand): LiveSession {
		const id = String(cmd.sessionId ?? "");
		const session = this.sessions.get(id);
		if (!session) throw new Error(`no such live session: ${id}`);
		return session;
	}

	private findSessionByApproval(approvalId: string | undefined): LiveSession | undefined {
		if (!approvalId) return undefined;
		for (const session of this.sessions.values()) {
			if (session.approvals.some(a => a.id === approvalId)) return session;
		}
		return undefined;
	}

	private machineInfo(): MachineInfo {
		return {
			name: hostname().replace(/\.local$/, ""),
			host: hostname(),
			bridgeVersion: BRIDGE_VERSION,
			ompVersion: this.ompVersion,
			platform: process.platform,
			uptimeSec: Math.round((Date.now() - this.startedAt) / 1000),
		};
	}

	private sendEvent(ws: WS, event: ServerEvent): void {
		try {
			ws.send(JSON.stringify(event));
		} catch {
			/* socket gone */
		}
	}

	private broadcast(event: ServerEvent): void {
		for (const ws of this.sockets) this.sendEvent(ws, event);
	}
}
