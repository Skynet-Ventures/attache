/**
 * Read-only view over omp's on-disk session storage:
 * `~/.omp/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl`
 *
 * Each jsonl begins with optional `{"type":"title",...}` and a
 * `{"type":"session","id","timestamp","cwd"}` line. We only read the head of
 * each file for listings, and stream the whole file for deep search.
 */

import { readdir, stat, open } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import type { ProjectGroup, SessionSummary } from "../types";

export function ompAgentDir(): string {
	return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".omp", "agent");
}

export function sessionsRoot(): string {
	return join(ompAgentDir(), "sessions");
}

interface HeadInfo {
	title: string | null;
	id: string | null;
	cwd: string | null;
}

async function readHead(path: string): Promise<HeadInfo> {
	const info: HeadInfo = { title: null, id: null, cwd: null };
	let fh;
	try {
		fh = await open(path, "r");
		const buf = Buffer.alloc(8_192);
		const { bytesRead } = await fh.read(buf, 0, buf.length, 0);
		const lines = buf.subarray(0, bytesRead).toString("utf-8").split("\n");
		for (const line of lines.slice(0, 6)) {
			if (!line.trim()) continue;
			try {
				const obj = JSON.parse(line) as Record<string, unknown>;
				if (obj.type === "title" && typeof obj.title === "string") info.title = obj.title;
				if (obj.type === "session") {
					if (typeof obj.id === "string") info.id = obj.id;
					if (typeof obj.cwd === "string") info.cwd = obj.cwd;
				}
			} catch {
				// A torn head line (concurrent write) — fine for listing purposes.
				break;
			}
			if (info.id && info.title) break;
		}
	} catch {
		/* unreadable file */
	} finally {
		await fh?.close();
	}
	return info;
}

function projectNameFor(cwd: string | null, bucket: string): string {
	if (cwd) return basename(cwd) || cwd;
	return bucket.replace(/^-+|-+$/g, "").split("-").pop() || bucket;
}

export interface StoredSession extends SessionSummary {
	bucket: string;
}

export async function listStoredSessions(limitPerProject = 25): Promise<StoredSession[]> {
	const root = sessionsRoot();
	let buckets: string[];
	try {
		buckets = await readdir(root);
	} catch {
		return [];
	}
	const out: StoredSession[] = [];
	for (const bucket of buckets) {
		const dir = join(root, bucket);
		let entries: string[];
		try {
			entries = (await readdir(dir)).filter(e => e.endsWith(".jsonl"));
		} catch {
			continue;
		}
		// Filenames sort chronologically (ISO timestamp prefix); newest first.
		entries.sort().reverse();
		for (const entry of entries.slice(0, limitPerProject)) {
			const path = join(dir, entry);
			let mtime: Date;
			try {
				mtime = (await stat(path)).mtime;
			} catch {
				continue;
			}
			const head = await readHead(path);
			const stem = entry.replace(/\.jsonl$/, "");
			const uuid = stem.split("_")[1] ?? stem;
			const title = head.title?.trim();
			out.push({
				id: `stored:${path}`,
				title: title && title.length > 0 ? title : `Untitled · ${(stem.split("_")[0] ?? "").slice(0, 10)}`,
				project: projectNameFor(head.cwd, bucket),
				cwd: head.cwd ?? bucket,
				sessionPath: path,
				updatedAt: mtime.toISOString(),
				live: false,
				status: "idle",
				shortId: `#${uuid.slice(-4)}`,
				bucket,
			});
		}
	}
	out.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
	return out;
}

export interface ProjectClaim {
	id: string;
	name: string;
	cwds: string[];
}

/**
 * Group sessions: custom projects first (in creation order, shown even when
 * empty), then auto-groups by cwd for unclaimed sessions.
 */
export function groupByProject(sessions: SessionSummary[], claims: ProjectClaim[] = []): ProjectGroup[] {
	const custom: ProjectGroup[] = claims.map(c => ({
		id: c.id,
		name: c.name,
		cwd: c.cwds[0] ?? "",
		custom: true,
		sessions: [],
	}));
	const byClaimedCwd = new Map<string, ProjectGroup>();
	for (let i = 0; i < claims.length; i++) {
		for (const cwd of claims[i]!.cwds) byClaimedCwd.set(cwd, custom[i]!);
	}
	const auto = new Map<string, ProjectGroup>();
	for (const s of sessions) {
		const claimed = byClaimedCwd.get(s.cwd);
		if (claimed) {
			claimed.sessions.push(s);
			continue;
		}
		let g = auto.get(s.cwd);
		if (!g) {
			g = { id: `auto:${s.cwd}`, name: s.project, cwd: s.cwd, custom: false, sessions: [] };
			auto.set(s.cwd, g);
		}
		g.sessions.push(s);
	}
	return [...custom, ...auto.values()];
}

/** Case-insensitive search across title, id and message text. */
export async function searchStoredSessions(query: string, limit = 30): Promise<StoredSession[]> {
	const q = query.toLowerCase();
	const all = await listStoredSessions(200);
	const hits: StoredSession[] = [];
	for (const s of all) {
		if (hits.length >= limit) break;
		if (s.title.toLowerCase().includes(q) || s.shortId.includes(q) || s.sessionPath.toLowerCase().includes(q)) {
			hits.push(s);
			continue;
		}
		// Deep scan: cheap streaming substring check over raw jsonl.
		try {
			const file = Bun.file(s.sessionPath);
			if (file.size > 32 * 1024 * 1024) continue; // skip pathological files
			const text = await file.text();
			if (text.toLowerCase().includes(q)) hits.push(s);
		} catch {
			/* ignore unreadable */
		}
	}
	return hits;
}

export interface SessionEntry {
	id: string;
	role: "user" | "assistant";
	preview: string;
	timestamp: string;
}

/**
 * Branchable entry points, read straight from a session jsonl (the RPC
 * message APIs don't expose entry ids). Works for any on-disk session file,
 * live or stored — the app branches without needing live observation.
 */
export async function readSessionEntries(path: string): Promise<SessionEntry[]> {
	let text: string;
	try {
		text = await Bun.file(path).text();
	} catch {
		return [];
	}
	const out: SessionEntry[] = [];
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
			const role = entry.message?.role;
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
