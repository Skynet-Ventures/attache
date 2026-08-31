import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseApproval, parseRuleScope, RuleStore } from "../src/approvals";
import type { RpcExtensionUIRequest } from "../src/types";

let dir: string;

beforeAll(async () => {
	dir = await mkdtemp(join(tmpdir(), "attache-scopes-"));
	process.env.ATTACHE_DIR = dir;
});

afterAll(async () => {
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

function approvalReq(tool: string, body: string, sessionId: string, id = "ui_x"): RpcExtensionUIRequest {
	return {
		type: "extension_ui_request",
		id,
		method: "select",
		title: `Allow tool: ${tool}\n${body}`,
		options: ["Approve", "Deny"],
	};
}

function approval(sessionId: string, tool = "bash", body = "$ make build"): ReturnType<typeof parseApproval> {
	return parseApproval(sessionId, approvalReq(tool, body, sessionId));
}

describe("scoped always-allow rules", () => {
	test("legacy rules without a scope field are treated as global", async () => {
		await writeFile(
			join(dir, "rules.json"),
			JSON.stringify([
				{ id: "r1", tool: "bash", pattern: "$ make build", createdAt: "2026-01-01T00:00:00Z", note: "n" },
			]),
		);
		const rules = new RuleStore();
		await rules.load();
		const rule = rules.match(approval("sess-a", "bash", "$ make build -j8"), { cwd: "/anywhere" });
		expect(rule).not.toBeNull();
		expect(rule!.scope).toEqual({ kind: "global" });
	});

	test("global scope rules match every session and cwd", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ cargo test"));
		expect(rules.match(approval("sess-a", "bash", "$ cargo test x"), { cwd: "/a" })).not.toBeNull();
		expect(rules.match(approval("sess-b", "bash", "$ cargo test x"), { cwd: "/b" })).not.toBeNull();
	});

	test("session-scoped rules match only their own bridge session id", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ yarn build"), {
			kind: "session",
			sessionId: "sess-a",
		});
		expect(rules.match(approval("sess-a", "bash", "$ yarn build"), { cwd: "/x" })).not.toBeNull();
		expect(rules.match(approval("sess-b", "bash", "$ yarn build"), { cwd: "/x" })).toBeNull();
	});

	test("cwd-scoped rules match only sessions rooted at that directory", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ git push"), { kind: "cwd", cwd: "/repo/attache" });
		expect(rules.match(approval("sess-a", "bash", "$ git push -f"), { cwd: "/repo/attache" })).not.toBeNull();
		expect(rules.match(approval("sess-b", "bash", "$ git push -f"), { cwd: "/repo/elsewhere" })).toBeNull();
	});

	test("precedence: a session rule wins over a cwd rule which wins over global", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ make deploy"), { kind: "global" });
		await rules.addFromApproval(approval("sess-a", "bash", "$ make deploy"), { kind: "cwd", cwd: "/srv" });
		await rules.addFromApproval(approval("sess-a", "bash", "$ make deploy"), {
			kind: "session",
			sessionId: "sess-a",
		});
		const matches = [
			rules.match(approval("sess-a", "bash", "$ make deploy --prod"), { cwd: "/srv" }),
			rules.match(approval("sess-a", "bash", "$ make deploy --prod"), { cwd: "/srv" }),
			rules.match(approval("sess-a", "bash", "$ make deploy --prod"), { cwd: "/srv" }),
		].map(r => r!.scope.kind);
		expect(matches).toEqual(["session", "session", "session"]);
		// Without a session-scoped rule, the cwd rule wins over the global one.
		expect(
			rules.match(approval("sess-b", "bash", "$ make deploy --prod"), { cwd: "/srv" })!.scope,
		).toEqual({ kind: "cwd", cwd: "/srv" });
		// Elsewhere only the global rule applies.
		expect(
			rules.match(approval("sess-b", "bash", "$ make deploy --prod"), { cwd: "/other" })!.scope,
		).toEqual({ kind: "global" });
	});

	test("scoped rules survive reload and list_rules reports the scope", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ kubectl apply"), {
			kind: "session",
			sessionId: "sess-a",
		});
		const reloaded = new RuleStore();
		await reloaded.load();
		const listed = reloaded.list();
		expect(listed).toHaveLength(1);
		expect(listed[0]!.scope).toEqual({ kind: "session", sessionId: "sess-a" });
		expect(reloaded.match(approval("sess-a", "bash", "$ kubectl apply -f x"), { cwd: "/x" })).not.toBeNull();
		expect(reloaded.match(approval("sess-other", "bash", "$ kubectl apply -f x"), { cwd: "/x" })).toBeNull();
	});

	test("addFromApproval with no scope persists a global rule (legacy back-compat)", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(approval("sess-a", "bash", "$ terraform plan"));
		const raw = JSON.parse(await Bun.file(join(dir, "rules.json")).text()) as Array<{ scope?: unknown }>;
		expect(raw).toHaveLength(1);
		expect(raw[0]!.scope).toEqual({ kind: "global" });
	});

	test("malformed scope values resolve to global at the boundary", async () => {
		expect(parseRuleScope({ kind: "cwd", cwd: "" })).toEqual({ kind: "global" });
		expect(parseRuleScope({ kind: "session", sessionId: 5 })).toEqual({ kind: "global" });
		expect(parseRuleScope({ kind: "bogus" })).toEqual({ kind: "global" });
		expect(parseRuleScope("global")).toEqual({ kind: "global" });
		expect(parseRuleScope(undefined)).toEqual({ kind: "global" });
		// Valid shapes pass through unchanged.
		expect(parseRuleScope({ kind: "cwd", cwd: "/x" })).toEqual({ kind: "cwd", cwd: "/x" });
		expect(parseRuleScope({ kind: "session", sessionId: "s1" })).toEqual({ kind: "session", sessionId: "s1" });
	});
});
