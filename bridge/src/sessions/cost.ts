/**
 * Bridge-side cost/token aggregation over the on-disk session index
 * (`get_cost_summary`). Usage rows come from the `usage` object attached to
 * each `message` entry in a session jsonl. Parsed rows are cached per file
 * keyed by mtime+size, so unchanged files are never rescanned.
 *
 * Rows with zero cost and zero tokens (aborted/empty turns, free models that
 * report 0) are excluded — a session file that never metered anything does not
 * show up in the summary.
 */

import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { sessionsRoot } from "./store";
import type { CostSummary } from "../types";

export interface CostQuery {
	/** Lookback in days; defaults to 30, clamped to [1, 365]. */
	days?: number;
	/** Custom project claims, used to attach projectId to by-project rows. */
	projects?: Array<{ id: string; cwds: string[] }>;
}

interface UsageRow {
	timestamp: string;
	costUSD: number;
	tokensIn: number;
	tokensOut: number;
}

interface ParsedUsageFile {
	sessionId: string;
	cwd: string;
	rows: UsageRow[];
}

interface FileIdentity {
	mtimeMs: number;
	size: number;
}

const CACHE_LIMIT = 512;
const usageCache = new Map<string, { identity: FileIdentity; parsed: ParsedUsageFile }>();

export async function getCostSummary(query: CostQuery = {}): Promise<CostSummary> {
	const lookback = clampDays(query.days);
	const cutoff = daysAgoDateString(lookback);
	const claimFor = new Map<string, string | null>();
	for (const project of query.projects ?? []) {
		for (const cwd of project.cwds) claimFor.set(cwd, project.id);
	}

	const daysAgg = new Map<string, { costUSD: number; tokensIn: number; tokensOut: number; sessions: Set<string> }>();
	const projectAgg = new Map<string, { projectId: string | null; costUSD: number; sessions: Set<string> }>();

	for (const file of await enumerateSessionFiles()) {
		const parsed = await loadParsedFile(file);
		if (!parsed) continue;
		for (const row of parsed.rows) {
			const date = localDateString(row.timestamp);
			if (!date || date < cutoff) continue;
			let day = daysAgg.get(date);
			if (!day) {
				day = { costUSD: 0, tokensIn: 0, tokensOut: 0, sessions: new Set() };
				daysAgg.set(date, day);
			}
			day.costUSD += row.costUSD;
			day.tokensIn += row.tokensIn;
			day.tokensOut += row.tokensOut;
			day.sessions.add(parsed.sessionId);

			let project = projectAgg.get(parsed.cwd);
			if (!project) {
				project = { projectId: claimFor.get(parsed.cwd) ?? null, costUSD: 0, sessions: new Set() };
				projectAgg.set(parsed.cwd, project);
			}
			project.costUSD += row.costUSD;
			project.sessions.add(parsed.sessionId);
		}
	}

	const days = [...daysAgg.entries()]
		.map(([date, d]) => ({
			date,
			costUSD: roundMoney(d.costUSD),
			tokensIn: d.tokensIn,
			tokensOut: d.tokensOut,
			sessions: d.sessions.size,
		}))
		.sort((a, b) => (a.date < b.date ? -1 : 1));

	const byProject = [...projectAgg.entries()]
		.map(([cwd, p]) => ({
			projectId: p.projectId,
			cwd,
			costUSD: roundMoney(p.costUSD),
			sessions: p.sessions.size,
		}))
		.sort((a, b) => b.costUSD - a.costUSD || (a.cwd < b.cwd ? -1 : 1));

	return { days, byProject };
}

function clampDays(days: number | undefined): number {
	if (typeof days !== "number" || !Number.isFinite(days)) return 30;
	return Math.max(1, Math.min(365, Math.floor(days)));
}

/** Local calendar date string (YYYY-MM-DD) `days` days ago (inclusive window end). */
function daysAgoDateString(days: number): string {
	const d = new Date();
	d.setDate(d.getDate() - (days - 1));
	return formatLocalDate(d);
}

function formatLocalDate(d: Date): string {
	const month = String(d.getMonth() + 1).padStart(2, "0");
	const day = String(d.getDate()).padStart(2, "0");
	return `${d.getFullYear()}-${month}-${day}`;
}

/** Local calendar date for an ISO timestamp; null when unparseable. */
function localDateString(iso: string): string | null {
	const d = new Date(iso);
	if (Number.isNaN(d.getTime())) return null;
	return formatLocalDate(d);
}

function roundMoney(value: number): number {
	return Math.round(value * 1000) / 1000;
}

/** Every session jsonl directly under each bucket (same scan as the session index). */
async function enumerateSessionFiles(): Promise<string[]> {
	const root = sessionsRoot();
	let buckets: string[];
	try {
		buckets = await readdir(root);
	} catch {
		return [];
	}
	const out: string[] = [];
	for (const bucket of buckets) {
		let entries: string[];
		try {
			entries = await readdir(join(root, bucket));
		} catch {
			continue;
		}
		for (const entry of entries) {
			if (entry.endsWith(".jsonl")) out.push(join(root, bucket, entry));
		}
	}
	return out;
}

async function loadParsedFile(path: string): Promise<ParsedUsageFile | null> {
	let identity: FileIdentity;
	try {
		const st = await stat(path);
		identity = { mtimeMs: st.mtimeMs, size: st.size };
	} catch {
		return null;
	}
	const cached = usageCache.get(path);
	if (cached && cached.identity.mtimeMs === identity.mtimeMs && cached.identity.size === identity.size) {
		return cached.parsed;
	}
	let text: string;
	try {
		text = await Bun.file(path).text();
	} catch {
		return null;
	}
	const parsed = parseUsageFile(text);
	if (parsed) {
		usageCache.set(path, { identity, parsed });
		if (usageCache.size > CACHE_LIMIT) {
			const oldest = usageCache.keys().next().value;
			if (oldest !== undefined) usageCache.delete(oldest);
		}
	}
	return parsed;
}

/** Parse a session jsonl: session identity header + metered message rows. */
function parseUsageFile(text: string): ParsedUsageFile | null {
	let sessionId = "";
	let cwd = "";
	const rows: UsageRow[] = [];
	for (const line of text.split("\n")) {
		if (!line.trim()) continue;
		let entry: {
			type?: string;
			timestamp?: string;
			cwd?: string;
			id?: string;
			usage?: {
				input?: unknown;
				output?: unknown;
				cacheRead?: unknown;
				cacheWrite?: unknown;
				cost?: Record<string, unknown>;
			};
		};
		try {
			entry = JSON.parse(line);
		} catch {
			continue; // torn line during a concurrent write
		}
		if (entry.type === "session") {
			if (typeof entry.id === "string" && entry.id) sessionId = entry.id;
			if (typeof entry.cwd === "string" && entry.cwd) cwd = entry.cwd;
			continue;
		}
		if (entry.type !== "message" || !entry.usage || typeof entry.timestamp !== "string") continue;
		const row = usageRow(entry.usage, entry.timestamp);
		if (row) rows.push(row);
	}
	if (!sessionId || rows.length === 0) return null;
	return { sessionId, cwd, rows };
}

function usageRow(
	usage: {
		input?: unknown;
		output?: unknown;
		cacheRead?: unknown;
		cacheWrite?: unknown;
		cost?: Record<string, unknown>;
	},
	timestamp: string,
): UsageRow | null {
	const costUSD = extractCost(usage.cost);
	const tokensIn =
		num(usage.input) + num(usage.cacheRead) + num(usage.cacheWrite);
	const tokensOut = num(usage.output);
	if (costUSD <= 0 && tokensIn <= 0 && tokensOut <= 0) return null;
	return { timestamp, costUSD, tokensIn, tokensOut };
}

function num(v: unknown): number {
	return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/**
 * Cost is usually reported as `usage.cost.total`; some providers only emit
 * the per-part breakdown, which we sum when total is absent.
 */
function extractCost(cost: Record<string, unknown> | undefined): number {
	if (!cost || typeof cost !== "object") return 0;
	const total = num(cost.total);
	if (total > 0) return total;
	const parts = ["input", "output", "cacheRead", "cacheWrite"] as const;
	const sum = parts.reduce((acc, key) => acc + num(cost[key]), 0);
	return sum;
}
