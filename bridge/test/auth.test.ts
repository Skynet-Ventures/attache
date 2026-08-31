import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Auth } from "../src/auth";

let dir: string;

beforeAll(async () => {
	dir = await mkdtemp(join(tmpdir(), "attache-auth-"));
	process.env.ATTACHE_DIR = dir;
});

afterAll(async () => {
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	// Fresh state dir per test — each pairing flow is self-contained.
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

describe("Auth pairing + tokens", () => {
	test("issueCode returns an 8-char code and persists it for a separate `pair` process", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		expect(code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);

		// A second, independent Auth instance (stands in for `pair`) reads the
		// same fresh code back from disk.
		const reader = new Auth();
		await reader.load();
		expect(reader.persistedCode).toBe(code);
		expect(reader.codeActive).toBe(true);
	});

	test("redeemCode exchanges a valid code for a token exactly once", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "TestPhone");
		expect(token).toBeTruthy();
		expect(token!.length).toBe(64); // 32 random bytes, hex-encoded
		expect(auth.codeActive).toBe(false);
		// Single-use: redeeming again with the same code fails.
		expect(await auth.redeemCode(code, "Second")).toBeNull();
	});

	test("redeemCode rejects wrong or missing codes", async () => {
		const auth = new Auth();
		await auth.load();
		await auth.issueCode();
		expect(await auth.redeemCode("ZZZZZZZZ", "x")).toBeNull();
		expect(await auth.redeemCode("", "x")).toBeNull();
	});

	test("verify accepts the issued token and rejects junk", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "iPhone");
		const device = await auth.verify(token);
		expect(device).not.toBeNull();
		expect(device!.name).toBe("iPhone");
		expect(auth.verify(null)).resolves.toBeNull();
		expect(await auth.verify("0".repeat(64))).toBeNull();
	});

	test("tokens are persisted only as SHA-256 hashes, never plaintext", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "Phone");
		const raw = await Bun.file(join(dir, "auth.json")).text();
		expect(token).toBeTruthy();
		expect(raw).not.toContain(token!);
		expect(raw).toContain('"tokenHash"');
	});

	test("revoke removes the device, invalidates its token, and is idempotent", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "OldPhone");
		const device = (await auth.verify(token))!;
		expect(await auth.revoke(device.id)).toBe(true);
		// The token is dead immediately.
		expect(await auth.verify(token)).toBeNull();
		expect(auth.listDevices()).toHaveLength(0);
		expect(await auth.revoke(device.id)).toBe(false);
	});

	test("listDevices never leaks token hashes to callers", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		await auth.redeemCode(code, "Phone");
		const devices = auth.listDevices();
		expect(devices).toHaveLength(1);
		expect(devices[0]).not.toHaveProperty("tokenHash");
		expect(devices[0]).toMatchObject({ name: "Phone" });
	});
});
