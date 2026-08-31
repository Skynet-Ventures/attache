import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RuleStore } from "../src/approvals";
import { LiveSession, type SessionProc } from "../src/sessions/live";
import type { RpcFrame, RpcResponseFrame, ServerEvent } from "../src/types";

let dir: string;

beforeAll(async () => {
	dir = await mkdtemp(join(tmpdir(), "attache-live-"));
	process.env.ATTACHE_DIR = dir;
});

afterAll(async () => {
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

/**
 * A scripted stand-in for the spawned `omp --mode rpc` child, so approval and
 * message-drain behavior can be exercised without a real agent process.
 */
class FakeProc implements SessionProc {
	onExit: ((code: number) => void) | null = null;
	requests: Array<Record<string, unknown>> = [];
	written: Array<Record<string, unknown>> = [];
	sent = false;
	private listeners = new Set<(frame: RpcFrame) => void>();
	private responders = new Map<string, (req: Record<string, unknown>) => RpcResponseFrame>();

	async start(): Promise<void> {}
	subscribe(listener: (frame: RpcFrame) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}
	async request(command: Record<string, unknown>, _timeoutMs?: number): Promise<RpcResponseFrame> {
		this.requests.push(command);
		const type = String(command.type);
		const responder = this.responders.get(type);
		if (responder) return responder(command);
		return { type: "response", id: `id_${this.requests.length}`, command: type, success: true };
	}
	write(frame: Record<string, unknown>): void {
		this.written.push(frame);
	}
	dispose(): void {}
	kill(): void {}

	/** Emit an inbound frame from the (mocked) omp child. */
	emit(frame: RpcFrame): void {
		for (const l of this.listeners) l(frame);
	}

	respondTo(type: string, responder: (req: Record<string, unknown>) => RpcResponseFrame): void {
		this.responders.set(type, responder);
	}
}

function approvalFrame(id: string, tool = "bash", body = "$ touch /tmp/attache-probe"): RpcFrame {
	return {
		type: "extension_ui_request",
		id,
		method: "select",
		title: `Allow tool: ${tool}\n${body}`,
		options: ["Approve", "Deny"],
	} as RpcFrame;
}

async function makeSession(proc: FakeProc, approvalTimeoutMs = 0): Promise<{ session: LiveSession; events: ServerEvent[] }> {
	const session = new LiveSession("/tmp", new RuleStore(), { proc, approvalTimeoutMs });
	const events: ServerEvent[] = [];
	session.subscribe(e => events.push(e));
	await session.start();
	return { session, events };
}

describe("LiveSession approval lifecycle (mocked omp)", () => {
	afterEach(() => vi.useRealTimers());

	test("pending approval is denied by timeout: Deny to omp + approval_resolved by timeout", async () => {
		vi.useFakeTimers();
		const proc = new FakeProc();
		const { session, events } = await makeSession(proc, 20);

		proc.emit(approvalFrame("ui_t1"));
		expect(session.approvals.map(a => a.id)).toEqual(["ui_t1"]);
		expect(events.some(e => e.type === "approval_request")).toBe(true);

		vi.advanceTimersByTime(20);
		expect(session.approvals).toHaveLength(0);
		const deny = proc.written.find(w => w.type === "extension_ui_response" && w.id === "ui_t1");
		expect(deny?.value).toBe("Deny");
		const resolved = events.filter(e => e.type === "approval_resolved" && "approvalId" in e && e.approvalId === "ui_t1");
		expect(resolved).toHaveLength(1);
		expect(resolved[0]).toMatchObject({ verdict: "deny", by: "timeout" });
		session.dispose();
	});

	test("app resolution cancels the timeout — no duplicate resolution", async () => {
		vi.useFakeTimers();
		const proc = new FakeProc();
		const { session, events } = await makeSession(proc, 20);

		proc.emit(approvalFrame("ui_t2"));
		await session.resolveApproval("ui_t2", "allow");
		vi.advanceTimersByTime(200);

		const resolved = events.filter(e => e.type === "approval_resolved" && "approvalId" in e && e.approvalId === "ui_t2");
		expect(resolved).toHaveLength(1);
		expect(resolved[0]).toMatchObject({ verdict: "allow", by: "app" });
		session.dispose();
	});

	test("a rule match auto-approves and requires no timer", async () => {
		vi.useFakeTimers();
		const proc = new FakeProc();
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval({
			id: "r1", sessionId: "s", tool: "bash", prompt: "", command: "$ touch /tmp/attache-probe",
			reason: null, risk: "medium", createdAt: "", options: ["Approve", "Deny"],
		});
		const session = new LiveSession("/tmp", rules, { proc, approvalTimeoutMs: 20 });
		const events: ServerEvent[] = [];
		session.subscribe(e => events.push(e));
		await session.start();
		proc.emit(approvalFrame("ui_r1"));
		expect(session.approvals).toHaveLength(0);
		expect(proc.written.find(w => w.type === "extension_ui_response")?.value).toBe("Approve");
		vi.advanceTimersByTime(200);
		expect(events.filter(e => e.type === "approval_resolved")).toHaveLength(1);
		session.dispose();
	});

	test("per-session yolo override auto-approves anything the agent still asks about", async () => {
		const proc = new FakeProc();
		const { session, events } = await makeSession(proc);
		session.setApprovalModeOverride("yolo");
		proc.emit(approvalFrame("ui_y1"));
		expect(session.approvals).toHaveLength(0);
		expect(proc.written.find(w => w.type === "extension_ui_response" && w.id === "ui_y1")?.value).toBe("Approve");
		const resolved = events.find(e => e.type === "approval_resolved" && "approvalId" in e && e.approvalId === "ui_y1");
		expect(resolved).toMatchObject({ verdict: "allow", by: "mode" });
		session.dispose();
	});

	test("available_commands_update is forwarded as a commands event", async () => {
		const proc = new FakeProc();
		const { session, events } = await makeSession(proc);
		proc.emit({ type: "available_commands_update", commands: [{ name: "security" }] } as RpcFrame);
		const cmd = events.find(e => e.type === "commands");
		expect(cmd).toEqual({ type: "commands", sessionId: session.id, commands: [{ name: "security" }] });
		session.dispose();
	});
});

describe("LiveSession.getMessages (mocked omp process)", () => {
	test("drains every page and returns the full transcript", async () => {
		const proc = new FakeProc();
		proc.respondTo("get_messages_page", req => {
			const cursor = req.cursor as string | undefined;
			if (cursor === undefined) {
				return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 1 }], totalMessages: 2, nextCursor: "c1" } };
			}
			return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 2 }], totalMessages: 2 } };
		});
		const { session, events } = await makeSession(proc);
		// live test also grabs messages via generated session — clear noise:
		events.length = 0;

		const result = await session.getMessages();
		expect(result).toEqual({ messages: [{ m: 1 }, { m: 2 }], totalMessages: 2 });
		const pageCalls = proc.requests.filter(r => r.type === "get_messages_page");
		expect(pageCalls.map(r => r.cursor)).toEqual([undefined, "c1"]);
		session.dispose();
	});

	test("session_busy is retried, then succeeds", async () => {
		let calls = 0;
		const proc = new FakeProc();
		proc.respondTo("get_messages_page", () => {
			calls += 1;
			if (calls === 1) return { type: "response", command: "get_messages_page", success: false, error: "busy", code: "session_busy" };
			return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 1 }], totalMessages: 1 } };
		});
		const { session } = await makeSession(proc);
		const result = await session.getMessages(undefined, undefined, { sleep: async () => {} });
		expect(result).toEqual({ messages: [{ m: 1 }], totalMessages: 1 });
		expect(calls).toBe(2);
		session.dispose();
	});

	test("session_busy past the budget surfaces a session_busy result code", async () => {
		const proc = new FakeProc();
		proc.respondTo("get_messages_page", () => ({
			type: "response", command: "get_messages_page", success: false, error: "busy", code: "session_busy",
		}));
		const { session } = await makeSession(proc);
		const err = (await session
			.getMessages(undefined, undefined, { sleep: async () => {}, maxBusyBackoffMs: 600, initialBackoffMs: 200 })
			.then(
				() => null,
				e => e as Error,
			)) as { code?: string } | null;
		expect(err).not.toBeNull();
		expect(err!.code).toBe("session_busy");
		session.dispose();
	});

	test("stale_cursor restarts the drain once, then succeeds", async () => {
		const proc = new FakeProc();
		let calls = 0;
		proc.respondTo("get_messages_page", req => {
			calls += 1;
			const cursor = req.cursor as string | undefined;
			if (calls === 1) return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 1 }], totalMessages: 1, nextCursor: "cX" } };
			if (calls === 2) return { type: "response", command: "get_messages_page", success: false, error: "stale", code: "stale_cursor" };
			return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 1 }], totalMessages: 1 } };
		});
		const { session } = await makeSession(proc);
		const result = await session.getMessages();
		expect(result).toEqual({ messages: [{ m: 1 }], totalMessages: 1 });
		expect(calls).toBe(3);
		session.dispose();
	});

	test("stale_cursor persisting surfaces a stale_cursor result code", async () => {
		const proc = new FakeProc();
		proc.respondTo("get_messages_page", req => {
			const cursor = req.cursor as string | undefined;
			if (cursor === undefined) return { type: "response", command: "get_messages_page", success: true, data: { messages: [{ m: 1 }], totalMessages: 1, nextCursor: "cX" } };
			return { type: "response", command: "get_messages_page", success: false, error: "stale", code: "stale_cursor" };
		});
		const { session } = await makeSession(proc);
		const err = (await session.getMessages().then(
			() => null,
			e => e as Error,
		)) as { code?: string } | null;
		expect(err).not.toBeNull();
		expect(err!.code).toBe("stale_cursor");
		session.dispose();
	});
});
