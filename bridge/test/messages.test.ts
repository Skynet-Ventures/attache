import { describe, expect, test } from "bun:test";
import { drainMessages } from "../src/messages";

const noSleep = () => Promise.resolve();

describe("drainMessages", () => {
	test("collects every page across the cursor chain", async () => {
		const calls: Array<{ cursor?: string }> = [];
		const fetchPage = async (cursor?: string) => {
			calls.push({ cursor });
			if (cursor === undefined) return { ok: true as const, messages: [{ m: 1 }], nextCursor: "c1" };
			if (cursor === "c1") return { ok: true as const, messages: [{ m: 2 }], nextCursor: "c2" };
			return { ok: true as const, messages: [{ m: 3 }], totalMessages: 3 };
		};
		const r = await drainMessages({ fetchPage, sleep: noSleep });
		expect(r).toEqual({ ok: true, messages: [{ m: 1 }, { m: 2 }, { m: 3 }], totalMessages: 3 });
		expect(calls.map(c => c.cursor)).toEqual([undefined, "c1", "c2"]);
	});

	test("startCursor seeds the first page request", async () => {
		const calls: Array<{ cursor?: string }> = [];
		const fetchPage = async (cursor?: string) => {
			calls.push({ cursor });
			return { ok: true as const, messages: [] as unknown[], totalMessages: 0 };
		};
		await drainMessages({ fetchPage, sleep: noSleep, startCursor: "c7" });
		expect(calls.map(c => c.cursor)).toEqual(["c7"]);
	});

	test("session_busy is retried with growing backoff until a page succeeds", async () => {
		let calls = 0;
		const sleeps: number[] = [];
		const fetchPage = async () => {
			calls += 1;
			if (calls === 1) return { ok: false as const, error: "session_busy" as const };
			return { ok: true as const, messages: [{ m: 1 }], totalMessages: 1 };
		};
		const r = await drainMessages({
			fetchPage,
			sleep: async ms => {
				sleeps.push(ms);
			},
			initialBackoffMs: 100,
			maxBusyBackoffMs: 10_000,
		});
		expect(r).toEqual({ ok: true, messages: [{ m: 1 }], totalMessages: 1 });
		expect(calls).toBe(2);
		expect(sleeps).toEqual([100]);
	});

	test("relentless session_busy exhausts the budget and surfaces session_busy", async () => {
		let calls = 0;
		const sleeps: number[] = [];
		const fetchPage = async () => {
			calls += 1;
			return { ok: false as const, error: "session_busy" as const };
		};
		const r = await drainMessages({
			fetchPage,
			sleep: async ms => {
				sleeps.push(ms);
			},
			initialBackoffMs: 250,
			maxBusyBackoffMs: 1_000,
		});
		expect(r).toEqual({ ok: false, error: "session_busy" });
		// 250+500+250 = 1000ms of scheduled retry, then the budget is spent.
		expect(sleeps).toEqual([250, 500, 250]);
		expect(calls).toBe(4);
	});

	test("stale_cursor restarts the walk once and succeeds", async () => {
		const calls: Array<{ cursor?: string }> = [];
		const fetchPage = async (cursor?: string) => {
			const n = calls.length;
			calls.push({ cursor });
			if (n === 0) return { ok: true as const, messages: [{ m: "a" }], nextCursor: "cA" };
			if (n === 1) return { ok: false as const, error: "stale_cursor" as const };
			// Restarted from the top: a consistent snapshot.
			return { ok: true as const, messages: [{ m: "a" }, { m: "b" }], totalMessages: 2 };
		};
		const r = await drainMessages({ fetchPage, sleep: noSleep });
		expect(r).toEqual({ ok: true, messages: [{ m: "a" }, { m: "b" }], totalMessages: 2 });
		expect(calls.map(c => c.cursor)).toEqual([undefined, "cA", undefined]);
	});

	test("stale_cursor twice surfaces stale_cursor", async () => {
		const fetchPage = async (cursor?: string) => {
			if (cursor === undefined) return { ok: true as const, messages: [{ m: 1 }], nextCursor: "cX" };
			return { ok: false as const, error: "stale_cursor" as const };
		};
		const r = await drainMessages({ fetchPage, sleep: noSleep });
		expect(r).toEqual({ ok: false, error: "stale_cursor" });
	});

	test("a stale_cursor on the first page still restarts exactly once", async () => {
		let calls = 0;
		const fetchPage = async (cursor?: string) => {
			calls += 1;
			if (cursor === undefined && calls === 1) return { ok: false as const, error: "stale_cursor" as const };
			return { ok: true as const, messages: [{ m: 1 }], totalMessages: 1 };
		};
		const r = await drainMessages({ fetchPage, sleep: noSleep });
		expect(r).toEqual({ ok: true, messages: [{ m: 1 }], totalMessages: 1 });
		expect(calls).toBe(2);
	});
});
