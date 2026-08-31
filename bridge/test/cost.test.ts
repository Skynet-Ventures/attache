import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getCostSummary } from "../src/sessions/cost";

let agentDir: string;
let sessionsDir: string;

const DAY_MS = 86_400_000;

function localDateString(ms: number): string {
	const d = new Date(ms);
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function iso(msAgoDays: number, suffix = "12:00:00.000Z"): string {
	return new Date(Date.now() - msAgoDays * DAY_MS).toISOString().replace(/T.*/, `T${suffix}`);
}

function message(id: string, daysAgo: number, opts: { cost: number; input?: number; output?: number; cacheWrite?: number }): string {
	const usage: Record<string, unknown> = {
		input: opts.input ?? 0,
		output: opts.output ?? 0,
		cacheRead: 0,
		cacheWrite: opts.cacheWrite ?? 0,
		cost: { total: opts.cost, input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	};
	return JSON.stringify({
		type: "message",
		id,
		timestamp: iso(daysAgo),
		message: { role: "assistant", content: [] },
		usage,
	});
}

function sessionLine(id: string, cwd: string, daysAgo: number): string {
	return JSON.stringify({ type: "session", version: 3, id, timestamp: iso(daysAgo), cwd });
}

beforeAll(async () => {
	agentDir = await mkdtemp(join(tmpdir(), "attache-cost-"));
	sessionsDir = join(agentDir, "sessions");
	process.env.PI_CODING_AGENT_DIR = agentDir;
});

afterAll(async () => {
	await rm(agentDir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(sessionsDir, { recursive: true, force: true });
	await mkdir(sessionsDir, { recursive: true });
});

async function writeSession(bucket: string, filename: string, lines: string[]): Promise<string> {
	const dir = join(sessionsDir, bucket);
	await mkdir(dir, { recursive: true });
	const path = join(dir, filename);
	await writeFile(path, lines.join("\n") + "\n");
	return path;
}

describe("getCostSummary over the session index", () => {
	test("aggregates cost and token usage per day and per project cwd", async () => {
		await writeSession("proj-a", "2026-01-01T00-00-00-000Z_sessaaaa.jsonl", [
			sessionLine("sess-aaaa", "/work/proj-a", 1),
			message("m1", 1, { cost: 1.5, input: 800, output: 2000, cacheWrite: 200 }),
			message("m2", 1, { cost: 0.5, output: 100 }),
			// Zero-cost, zero-token aborted turn: must not appear.
			message("m3", 1, { cost: 0 }),
			// Older than the 30-day window: excluded.
			message("m4", 40, { cost: 9.99, output: 500 }),
		]);
		await writeSession("proj-b", "2026-01-02T00-00-00-000Z_sessbbbb.jsonl", [
			sessionLine("sess-bbbb", "/work/proj-b", 1),
			message("n1", 1, { cost: 2.0, input: 5000, output: 3000 }),
			message("n2", 2, { cost: 0.25, input: 50, output: 10 }),
		]);
		await writeSession("proj-b", "2026-01-03T00-00-00-000Z_sesscccc.jsonl", [
			sessionLine("sess-cccc", "/work/proj-b", 1),
			message("p1", 1, { cost: 0.75, output: 40 }),
		]);

		const summary = await getCostSummary();
		const todayMinus1 = localDateString(Date.now() - DAY_MS);
		const todayMinus2 = localDateString(Date.now() - 2 * DAY_MS);

		expect(summary.days).toEqual([
			{
				date: todayMinus2,
				costUSD: 0.25,
				tokensIn: 50,
				tokensOut: 10,
				sessions: 1,
			},
			{
				date: todayMinus1,
				costUSD: 4.75,
				tokensIn: 6000, // 800 + 200 (cacheWrite) + 5000
				tokensOut: 5140, // 2000 + 100 + 3000 + 40
				sessions: 3,
			},
		]);

		expect(summary.byProject).toEqual([
			{ projectId: null, cwd: "/work/proj-b", costUSD: 3.0, sessions: 2 },
			{ projectId: null, cwd: "/work/proj-a", costUSD: 2.0, sessions: 1 },
		]);
	});

	test("attaches the custom project id for claimed cwds", async () => {
		await writeSession("proj-a", "2026-01-01T00-00-00-000Z_sessd1.jsonl", [
			sessionLine("sess-d1", "/work/claimed", 1),
			message("m1", 1, { cost: 1.0, input: 10, output: 20 }),
		]);
		const summary = await getCostSummary({ projects: [{ id: "proj-1", cwds: ["/work/claimed"] }] });
		expect(summary.byProject).toHaveLength(1);
		expect(summary.byProject[0]).toMatchObject({ projectId: "proj-1", cwd: "/work/claimed", costUSD: 1.0, sessions: 1 });
	});

	test("the days lookback window is honored", async () => {
		await writeSession("proj-a", "2026-01-01T00-00-00-000Z_sesse1.jsonl", [
			sessionLine("sess-e1", "/work/a", 1),
			message("m1", 1, { cost: 1.0, output: 10 }),
			message("m2", 5, { cost: 2.0, output: 20 }),
			message("m3", 10, { cost: 4.0, output: 40 }),
		]);
		const summary = await getCostSummary({ days: 3 });
		expect(summary.days).toHaveLength(1);
		expect(summary.days[0]!.costUSD).toBeCloseTo(1.0, 9);
	});

	test("unchanged files are not rescanned; modified files invalidate the cache", async () => {
		const path = await writeSession("proj-a", "2026-01-01T00-00-00-000Z_sessf1.jsonl", [
			sessionLine("sess-f1", "/work/a", 1),
			message("m1", 1, { cost: 1.0, output: 10 }),
		]);
		const first = await getCostSummary();
		const second = await getCostSummary();
		expect(second).toEqual(first);

		// A concurrent write appends usage — the mtime changes and the cached
		// parse must be dropped so the new row shows up.
		await writeFile(
			path,
			(await Bun.file(path).text()) + message("m2", 1, { cost: 3.0, output: 30 }) + "\n",
		);
		const third = await getCostSummary();
		expect(third.days[0]!.costUSD).toBeCloseTo(4.0, 9);
		expect(third.days[0]!.tokensOut).toBe(40);
	});

	test("empty index yields an empty summary", async () => {
		const summary = await getCostSummary();
		expect(summary).toEqual({ days: [], byProject: [] });
	});
});
