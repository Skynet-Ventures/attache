import { describe, expect, test } from "bun:test";
import { RpcFrameDecoder } from "../src/rpc/frames";
import { isApprovalSelect, parseApproval } from "../src/approvals";
import type { RpcExtensionUIRequest } from "../src/types";

describe("RpcFrameDecoder", () => {
	test("decodes plain NDJSON, tolerating split writes", () => {
		const d = new RpcFrameDecoder();
		expect(d.push('{"type":"ready","protocolVersion":1}\n{"type":"agent_')).toEqual([
			{ type: "ready", protocolVersion: 1 },
		]);
		expect(d.push('start"}\n')).toEqual([{ type: "agent_start" }]);
	});

	test("reassembles rpc_chunk sequences", () => {
		const payload = JSON.stringify({ type: "response", command: "get_messages", success: true, data: "x".repeat(50) });
		const bytes = new TextEncoder().encode(payload);
		const half = Math.ceil(bytes.length / 2);
		const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
		const d = new RpcFrameDecoder();
		const chunk = (index: number, data: Uint8Array) =>
			`${JSON.stringify({ type: "rpc_chunk", chunkId: "c1", index, count: 2, byteLength: bytes.length, data: b64(data) })}\n`;
		expect(d.push(chunk(0, bytes.subarray(0, half)))).toEqual([]);
		const frames = d.push(chunk(1, bytes.subarray(half)));
		expect(frames).toHaveLength(1);
		expect((frames[0] as { data: string }).data).toBe("x".repeat(50));
	});

	test("drops interrupted chunk sequences but keeps the interrupting frame", () => {
		const d = new RpcFrameDecoder();
		d.push(
			`${JSON.stringify({ type: "rpc_chunk", chunkId: "c1", index: 0, count: 2, byteLength: 10, data: btoa("hello") })}\n`,
		);
		const frames = d.push('{"type":"agent_end","messages":[]}\n');
		expect(frames).toEqual([{ type: "agent_end", messages: [] }]);
	});
});

describe("project grouping", () => {
	const session = (id: string, cwd: string) => ({
		id, title: id, project: cwd.split("/").pop()!, cwd, sessionPath: "",
		updatedAt: "2026-01-01T00:00:00Z", live: false, status: "idle" as const, shortId: `#${id}`,
	});

	test("custom projects claim cwds and show even when empty", async () => {
		const { groupByProject } = await import("../src/sessions/store");
		const groups = groupByProject(
			[session("a", "/src/ezpz"), session("b", "/src/other")],
			[
				{ id: "p1", name: "ezpz", cwds: ["/src/ezpz"] },
				{ id: "p2", name: "empty", cwds: [] },
			],
		);
		expect(groups.map(g => g.name)).toEqual(["ezpz", "empty", "other"]);
		expect(groups[0]!.custom).toBe(true);
		expect(groups[0]!.sessions).toHaveLength(1);
		expect(groups[1]!.sessions).toHaveLength(0);
		expect(groups[2]!.custom).toBe(false);
	});
});

describe("approval parsing", () => {
	const req: RpcExtensionUIRequest = {
		type: "extension_ui_request",
		id: "ui_9",
		method: "select",
		title: "Allow tool: bash\nReason: Critical pattern detected\n$ rm -rf tmp/profiles.old",
		options: ["Approve", "Deny"],
	};

	test("detects approval selects", () => {
		expect(isApprovalSelect(req)).toBe(true);
		expect(isApprovalSelect({ ...req, title: "Branch name" })).toBe(false);
	});

	test("extracts tool, reason, command, risk", () => {
		const a = parseApproval("s1", req);
		expect(a.tool).toBe("bash");
		expect(a.reason).toBe("Critical pattern detected");
		expect(a.command).toContain("rm -rf tmp/profiles.old");
		expect(a.risk).toBe("high");
	});

	test("mcp tools rank low risk", () => {
		const a = parseApproval("s1", {
			...req,
			title: "Allow tool: mcp__github_create_pr\nOrigin: MCP server tool",
		});
		expect(a.risk).toBe("low");
	});
});
