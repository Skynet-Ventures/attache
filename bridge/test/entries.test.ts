import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BridgeServer } from "../src/server";
import { readSessionEntries } from "../src/sessions/store";
import { LiveSession, type SessionProc } from "../src/sessions/live";
import { RuleStore } from "../src/approvals";
import type { RpcFrame, RpcResponseFrame } from "../src/types";

let dir: string;
let server: BridgeServer | null = null;

beforeAll(async () => {
	dir = await mkdtemp(join(tmpdir(), "attache-entries-"));
	process.env.ATTACHE_DIR = dir;
	process.env.PI_CODING_AGENT_DIR = join(dir, "omp");
});

afterAll(async () => {
	await server?.shutdown("test done");
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

afterEach(async () => {
	await server?.shutdown("test done");
	server = null;
});

function storedLine(obj: unknown): string {
	return JSON.stringify(obj);
}

async function writeStoredFixture(): Promise<string> {
	const sessions = join(dir, "omp", "agent", "sessions", "proj-a");
	await mkdir(sessions, { recursive: true });
	const path = join(sessions, "2026-01-01T00-00-00-000Z_abc12345.jsonl");
	const lines = [
		storedLine({ type: "title", v: 1, title: "Fixture session", updatedAt: "2026-01-01T00:00:00Z" }),
		storedLine({ type: "session", version: 3, id: "abc12345", timestamp: "2026-01-01T00:00:00Z", cwd: "/work/fixture" }),
		storedLine({ type: "message", id: "entry-1", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: [{ type: "text", text: "  Find the bug in checkout  " }] } }),
		storedLine({ type: "message", id: "entry-2", timestamp: "2026-01-01T00:00:02Z", message: { role: "assistant", content: [{ type: "text", text: "I found it, it's in fee.ts." }] } }),
		// Tool messages are not branchable entry points.
		storedLine({ type: "message", id: "entry-3", timestamp: "2026-01-01T00:00:03Z", message: { role: "tool", content: [{ type: "text", text: "ok" }] } }),
		// Twice-whitespace content is skipped (no meaningful preview).
		storedLine({ type: "message", id: "entry-4", timestamp: "2026-01-01T00:00:04Z", message: { role: "user", content: [{ type: "text", text: "   " }] } }),
		// A torn line must not abort the scan.
		'{"type":"message","id":"entry-5","timestamp":"2026-01-01T00:00:05Z", "message": {"role": "user", "content": ',
	];
	await writeFile(path, lines.join("\n") + "\n");
	return path;
}

describe("readSessionEntries (stored sessions)", () => {
	test("extracts user/assistant text entries from a stored jsonl", async () => {
		const path = await writeStoredFixture();
		const entries = await readSessionEntries(path);
		expect(entries).toEqual([
			{ id: "entry-1", role: "user", preview: "Find the bug in checkout", timestamp: "2026-01-01T00:00:01Z" },
			{ id: "entry-2", role: "assistant", preview: "I found it, it's in fee.ts.", timestamp: "2026-01-01T00:00:02Z" },
		]);
	});

	test("missing file yields an empty list", async () => {
		expect(await readSessionEntries(join(dir, "does-not-exist.jsonl"))).toEqual([]);
	});
});

describe("server get_entries dispatch", () => {
	test("reads stored entries for a stored:<path> id without a live session", async () => {
		const path = await writeStoredFixture();
		server = new BridgeServer({ port: 0, host: "127.0.0.1" });
		const { url, code } = await server.start();
		const pair = (await (await fetch(`${url}/pair`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ code, deviceName: "test-phone" }),
		})).json()) as { token: string; pushKey: string };

		expect(pair.token).toBeTruthy();
		expect(Buffer.from(pair.pushKey, "base64")).toHaveLength(32);

		const ws = new WebSocket(`${url.replace(/^http/, "ws")}/ws?token=${pair.token}`);
		const connected = Promise.withResolvers<void>();
		ws.onopen = () => connected.resolve();
		ws.onerror = () => connected.reject(new Error("ws failed"));
		await connected.promise;
		try {
			const result = await wsCommand(ws, {
				type: "get_entries",
				sessionId: `stored:${path}`,
			});
			expect((result as { entries: unknown[] }).entries).toHaveLength(2);
			expect((result as { entries: Array<{ id: string }> }).entries[0]).toMatchObject({ id: "entry-1" });
		} finally {
			ws.close();
		}
	});
});

class FakeProc implements SessionProc {
	onExit: ((code: number) => void) | null = null;
	private listeners = new Set<(frame: RpcFrame) => void>();
	private responses: Record<string, RpcResponseFrame> = {};

	async start(): Promise<void> {}
	subscribe(listener: (frame: RpcFrame) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}
	async request(command: Record<string, unknown>): Promise<RpcResponseFrame> {
		return this.responses[String(command.type)] ?? {
			type: "response",
			id: "x",
			command: String(command.type),
			success: true,
		};
	}
	write(): void {}
	dispose(): void {}
	kill(): void {}

	respondTo(type: string, frame: RpcResponseFrame): void {
		this.responses[type] = frame;
	}
}

describe("LiveSession.getEntries", () => {
	test("reads entries from the session snapshot file", async () => {
		const path = await writeStoredFixture();
		const proc = new FakeProc();
		proc.respondTo("get_state", {
			type: "response",
			id: "x",
			command: "get_state",
			success: true,
			data: { sessionName: "fixture", sessionFile: path, cwd: "/work/fixture", messageCount: 2 },
		});
		const session = new LiveSession("/work/fixture", new RuleStore(), { proc });
		await session.start();
		const entries = await session.getEntries();
		expect(entries).toHaveLength(2);
		expect(entries[0]).toMatchObject({ id: "entry-1", role: "user" });
		session.dispose();
	});
});

function wsCommand(ws: WebSocket, cmd: Record<string, unknown>): Promise<unknown> {
	const { promise, resolve, reject } = Promise.withResolvers<unknown>();
	const id = crypto.randomUUID();
	const onMessage = (ev: MessageEvent) => {
		const frame = JSON.parse(String(ev.data)) as {
			type: string;
			id?: string;
			ok?: boolean;
			data?: unknown;
			error?: string;
			code?: string;
		};
		if (frame.type !== "result" || frame.id !== id) return;
		ws.removeEventListener("message", onMessage);
		if (frame.ok) resolve(frame.data);
		else reject(new Error(`${frame.error ?? "command failed"}${frame.code ? ` (${frame.code})` : ""}`));
	};
	ws.addEventListener("message", onMessage);
	ws.send(JSON.stringify({ ...cmd, id }));
	return promise;
}
