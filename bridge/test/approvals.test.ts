import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseApproval, RuleStore } from "../src/approvals";
import { ApprovalTimer } from "../src/approval-timer";
import type { RpcExtensionUIRequest } from "../src/types";

let dir: string;

beforeAll(async () => {
	dir = await mkdtemp(join(tmpdir(), "attache-approvals-"));
	process.env.ATTACHE_DIR = dir;
});

afterAll(async () => {
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

function approvalReq(tool: string, body: string, id = "ui_x"): RpcExtensionUIRequest {
	return {
		type: "extension_ui_request",
		id,
		method: "select",
		title: `Allow tool: ${tool}\n${body}`,
		options: ["Approve", "Deny"],
	};
}

describe("approval parsing", () => {
	test("extracts tool, reason, command and classifies risk", () => {
		const a = parseApproval("s1", approvalReq("bash", "Reason: Critical pattern detected\n$ rm -rf tmp/profiles.old"));
		expect(a.tool).toBe("bash");
		expect(a.reason).toBe("Critical pattern detected");
		expect(a.command).toContain("rm -rf tmp/profiles.old");
		expect(a.risk).toBe("high");
	});

	test("varies risk by tool and reason", () => {
		expect(parseApproval("s1", approvalReq("eval", "$ mkfs.ext4 /dev/sdb1")).risk).toBe("high");
		expect(parseApproval("s1", approvalReq("mcp__github_create_pr", "Origin: MCP server tool")).risk).toBe("low");
		expect(parseApproval("s1", approvalReq("read", "reason: read file")).risk).toBe("low");
		expect(parseApproval("s1", approvalReq("write", "always fine")).risk).toBe("medium");
	});
});

describe("always-allow rule matching", () => {
	test("command-prefix rule matches its own prefix only", async () => {
		const rules = new RuleStore();
		await rules.load();
		const rule = await rules.addFromApproval(parseApproval("s1", approvalReq("bash", "$ git commit -am x", "a1")));
		expect(rule.pattern).toBe("$ git commit");
		expect(rules.match(parseApproval("s1", approvalReq("bash", "$ git commit -am y", "a2")), { cwd: "/tmp" })).not.toBeNull();
		expect(rules.match(parseApproval("s1", approvalReq("bash", "$ git push origin main", "a3")), { cwd: "/tmp" })).toBeNull();
		// Tool mismatch alone blocks the match.
		expect(rules.match(parseApproval("s1", approvalReq("write", "$ git commit -am z", "a4")), { cwd: "/tmp" })).toBeNull();
	});

	test("tool-only rule (no command) matches any command for that tool", async () => {
		const rules = new RuleStore();
		await rules.load();
		// Approval with no command detail → tool-only rule.
		await rules.addFromApproval(parseApproval("s1", approvalReq("write", "", "a1")));
		expect(rules.match(parseApproval("s1", approvalReq("write", "anything at all", "a2")), { cwd: "/tmp" })).not.toBeNull();
		expect(rules.match(parseApproval("s1", approvalReq("bash", "anything", "a3")), { cwd: "/tmp" })).toBeNull();
	});

	test("rules survive reload from disk", async () => {
		const rules = new RuleStore();
		await rules.load();
		await rules.addFromApproval(parseApproval("s1", approvalReq("bash", "$ cargo build", "a1")));
		const reloaded = new RuleStore();
		await reloaded.load();
		expect(reloaded.match(parseApproval("s1", approvalReq("bash", "$ cargo build --release", "a2")), { cwd: "/tmp" })).not.toBeNull();
	});
});

describe("approval timeout", () => {
	afterEach(() => vi.useRealTimers());

	test("fires after the budget, exactly once", () => {
		vi.useFakeTimers();
		const fired: string[] = [];
		const timer = new ApprovalTimer(30, id => fired.push(id));
		timer.start("a1");
		expect(fired).toEqual([]);
		vi.advanceTimersByTime(30);
		expect(fired).toEqual(["a1"]);
		vi.advanceTimersByTime(200);
		expect(fired).toEqual(["a1"]);
	});

	test("cancel prevents firing", () => {
		vi.useFakeTimers();
		const fired: string[] = [];
		const timer = new ApprovalTimer(30, id => fired.push(id));
		timer.start("a1");
		timer.cancel("a1");
		vi.advanceTimersByTime(100);
		expect(fired).toEqual([]);
	});

	test("a non-positive budget disables the timer entirely", () => {
		vi.useFakeTimers();
		const fired: string[] = [];
		const timer = new ApprovalTimer(0, id => fired.push(id));
		timer.start("a1");
		vi.advanceTimersByTime(100);
		expect(fired).toEqual([]);
	});

	test("duplicate starts do not double-fire", () => {
		vi.useFakeTimers();
		const fired: string[] = [];
		const timer = new ApprovalTimer(30, id => fired.push(id));
		timer.start("a1");
		timer.start("a1");
		vi.advanceTimersByTime(100);
		expect(fired).toEqual(["a1"]);
	});

	test("clear cancels every outstanding timer", () => {
		vi.useFakeTimers();
		const fired: string[] = [];
		const timer = new ApprovalTimer(30, id => fired.push(id));
		timer.start("a1");
		timer.start("a2");
		timer.clear();
		vi.advanceTimersByTime(100);
		expect(fired).toEqual([]);
	});
});
