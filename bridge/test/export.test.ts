import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LiveSession, type SessionProc } from "../src/sessions/live";
import { RuleStore } from "../src/approvals";
import { ProtocolError } from "../src/errors";
import type { RpcFrame, RpcResponseFrame } from "../src/types";

/**
 * A scripted `omp` stand-in that honors `export_html { outputPath }` by
 * writing `content` to the requested path, exactly like omp does.
 */
class ExportProc implements SessionProc {
	onExit: ((code: number) => void) | null = null;

	constructor(private readonly content: Buffer) {}

	async start(): Promise<void> {}
	subscribe(_listener: (frame: RpcFrame) => void): () => void {
		return () => {};
	}
	async request(command: Record<string, unknown>): Promise<RpcResponseFrame> {
		if (command.type === "export_html") {
			const outputPath = String(command.outputPath);
			await writeFile(outputPath, this.content);
			return { type: "response", id: "x", command: "export_html", success: true, data: { outputPath } };
		}
		return { type: "response", id: "x", command: String(command.type), success: true };
	}
	write(_frame: Record<string, unknown>): void {}
	dispose(): void {}
	kill(): void {}
}

async function exportWith(content: Buffer): Promise<{ html: string }> {
	const session = new LiveSession("/tmp", new RuleStore(), { proc: new ExportProc(content) });
	await session.start();
	try {
		return await session.exportHtml();
	} finally {
		session.dispose();
	}
}

describe("LiveSession.exportHtml", () => {
	test("returns the exported file base64-encoded", async () => {
		const content = Buffer.from("<html><body>hello</body></html>");
		const result = await exportWith(content);
		expect(result.html).toBe(content.toString("base64"));
	});

	test("a file over the 20MB cap surfaces a too_large error", async () => {
		const oversized = Buffer.alloc(20 * 1024 * 1024 + 1, 0x61);
		const err = await exportWith(oversized).then(
			() => null,
			e => e as Error,
		);
		expect(err).not.toBeNull();
		expect(err).toBeInstanceOf(ProtocolError);
		expect((err as ProtocolError).code).toBe("too_large");
	});

	test("a file exactly at the cap is accepted", async () => {
		const atCap = Buffer.alloc(20 * 1024 * 1024, 0x61);
		const result = await exportWith(atCap);
		expect(result.html.length).toBeGreaterThan(0);
		await rm(join(tmpdir(), "unused"), { force: true });
		const recovered = Buffer.from(result.html, "base64");
		expect(recovered.equals(atCap)).toBe(true);
	});
});
