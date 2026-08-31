/**
 * Approval interception and bridge-side "always allow" rules.
 *
 * omp surfaces tool approvals as extension UI `select` requests whose title is
 * the output of `formatApprovalPrompt` ("Allow tool: <name>\n..."), with
 * options ["Approve", "Deny"]. We parse those into structured requests for the
 * app, and answer omp with `extension_ui_response`.
 */

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AlwaysRule, ApprovalRequest, RpcExtensionUIRequest } from "./types";

export function attacheDir(): string {
	return process.env.ATTACHE_DIR ?? join(homedir(), ".attache");
}

const RULES_FILE = () => join(attacheDir(), "rules.json");

export function isApprovalSelect(req: RpcExtensionUIRequest): boolean {
	return (
		req.method === "select" &&
		typeof req.title === "string" &&
		req.title.startsWith("Allow tool: ") &&
		Array.isArray(req.options) &&
		req.options.includes("Approve") &&
		req.options.includes("Deny")
	);
}

const DESTRUCTIVE_HINTS = /rm\s+-rf|sudo\b|mkfs|shutdown|reboot|:\(\)\s*{|>[>]?\s*\/etc\/|curl[^\n]*\|\s*(ba)?sh|dd\s+if=/i;

export function parseApproval(sessionId: string, req: RpcExtensionUIRequest): ApprovalRequest {
	const title = req.title ?? "";
	const lines = title.split("\n");
	const tool = (lines[0] ?? "").replace(/^Allow tool:\s*/, "").trim() || "unknown";
	let reason: string | null = null;
	const detailLines: string[] = [];
	for (const line of lines.slice(1)) {
		if (line.startsWith("Reason: ")) reason = line.slice("Reason: ".length);
		else if (line.trim().length > 0) detailLines.push(line);
	}
	// The bash tool's approval details include the command itself; other tools
	// include paths/args. Treat the first detail block as the "command".
	const command = detailLines.length > 0 ? detailLines.join("\n") : null;

	let risk: ApprovalRequest["risk"] = "medium";
	if (tool === "bash" || tool === "eval") {
		risk = command && DESTRUCTIVE_HINTS.test(command) ? "high" : "medium";
	} else if (reason && /critical|destructive|dangerous/i.test(reason)) {
		risk = "high";
	} else if (tool.startsWith("mcp__") || tool === "read" || tool === "grep" || tool === "glob") {
		risk = "low";
	}
	if (reason && /critical/i.test(reason)) risk = "high";

	return {
		id: req.id,
		sessionId,
		tool,
		prompt: title,
		command,
		reason,
		risk,
		createdAt: new Date().toISOString(),
		options: req.options ?? ["Approve", "Deny"],
	};
}

// ---------------------------------------------------------------------------
// Always-allow rules
// ---------------------------------------------------------------------------

export class RuleStore {
	private rules: AlwaysRule[] = [];
	private loaded = false;

	async load(): Promise<void> {
		if (this.loaded) return;
		try {
			const raw = await readFile(RULES_FILE(), "utf-8");
			this.rules = JSON.parse(raw) as AlwaysRule[];
		} catch {
			this.rules = [];
		}
		this.loaded = true;
	}

	async persist(): Promise<void> {
		await mkdir(attacheDir(), { recursive: true });
		await writeFile(RULES_FILE(), JSON.stringify(this.rules, null, 2));
	}

	list(): AlwaysRule[] {
		return [...this.rules];
	}

	async remove(id: string): Promise<boolean> {
		const before = this.rules.length;
		this.rules = this.rules.filter(r => r.id !== id);
		if (this.rules.length !== before) {
			await this.persist();
			return true;
		}
		return false;
	}

	/**
	 * Record a rule derived from an approved request. For bash we key on the
	 * first token pair of the command (e.g. "rm -rf tmp/" style prefixes are
	 * intentionally NOT generalized past the second path segment); for other
	 * tools we match the tool name exactly.
	 */
	async addFromApproval(approval: ApprovalRequest): Promise<AlwaysRule> {
		const pattern = approval.command ? commandPrefix(approval.command) : null;
		const rule: AlwaysRule = {
			id: crypto.randomUUID(),
			tool: approval.tool,
			pattern,
			createdAt: new Date().toISOString(),
			note: pattern
				? `allow ${approval.tool}: ${pattern}…`
				: `allow tool ${approval.tool}`,
		};
		this.rules.push(rule);
		await this.persist();
		return rule;
	}

	match(approval: ApprovalRequest): AlwaysRule | null {
		for (const rule of this.rules) {
			if (rule.tool !== approval.tool) continue;
			if (rule.pattern === null) return rule;
			if (approval.command && normalize(approval.command).startsWith(rule.pattern)) return rule;
		}
		return null;
	}
}

function normalize(cmd: string): string {
	return cmd.trim().replace(/\s+/g, " ");
}

function commandPrefix(cmd: string): string {
	const norm = normalize(cmd);
	const tokens = norm.split(" ");
	// Keep the executable, its flags, and the first path argument — enough to
	// scope "rm -rf tmp/profiles.old" to "rm -rf tmp/profiles.old"-alikes
	// without blessing arbitrary rm -rf.
	return tokens.slice(0, Math.min(tokens.length, 3)).join(" ");
}
