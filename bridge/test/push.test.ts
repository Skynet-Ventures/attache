import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { createDecipheriv } from "node:crypto";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ApnsTransport, Push, pushDecrypt, pushEncrypt } from "../src/push";
import { Auth } from "../src/auth";
import type { PushPayload } from "../src/push";

interface RecordedRequest {
	url: string;
	init: { method?: string; headers?: Record<string, string>; body?: string };
}

/** Replace global fetch with a recorder; restore it after each test. */
function mockFetch(status = 200): { requests: RecordedRequest[] } {
	const requests: RecordedRequest[] = [];
	let nextStatus = status;
	globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
		requests.push({
			url: String(input),
			init: {
				method: init?.method,
				headers: (init?.headers ?? {}) as Record<string, string>,
				body: typeof init?.body === "string" ? init.body : undefined,
			},
		});
		return new Response("ok", { status: nextStatus });
	}) as typeof fetch;
	return { requests };
}

let realFetch: typeof fetch;
let dir: string;

beforeAll(async () => {
	realFetch = globalThis.fetch;
	dir = await mkdtemp(join(tmpdir(), "attache-push-"));
	process.env.ATTACHE_DIR = dir;
});

afterAll(async () => {
	await rm(dir, { recursive: true, force: true });
});

beforeEach(async () => {
	await rm(dir, { recursive: true, force: true });
	await mkdir(dir, { recursive: true });
});

afterEach(() => {
	globalThis.fetch = realFetch;
});

const payload: PushPayload = {
	kind: "approval",
	title: "Approval: bash",
	body: "$ rm -rf dist",
	sessionId: "sess-1",
	approvalId: "ui_1",
};

/**
 * Independent AES-256-GCM decrypt that asserts the wire format: 12-byte IV
 * prepended, 16-byte auth tag appended. Anything a standards-compliant
 * consumer (e.g. Apple CryptoKit in the notification service extension) can
 * read must decrypt under this layout.
 */
function decryptManually(ciphertextBase64: string, keyBase64: string): PushPayload {
	const key = Buffer.from(keyBase64, "base64");
	const data = Buffer.from(ciphertextBase64, "base64");
	expect(data.byteLength).toBeGreaterThan(12 + 16);
	const iv = data.subarray(0, 12);
	const tag = data.subarray(data.byteLength - 16);
	const body = data.subarray(12, data.byteLength - 16);
	const decipher = createDecipheriv("aes-256-gcm", key, iv);
	decipher.setAuthTag(tag);
	return JSON.parse(Buffer.concat([decipher.update(body), decipher.final()]).toString("utf8")) as PushPayload;
}

describe("push payload encryption (AES-256-GCM)", () => {
	test("round-trips through pushEncrypt/pushDecrypt", () => {
		const key = Buffer.from("k".repeat(32)).toString("base64");
		const ciphertext = pushEncrypt(payload, key);
		expect(pushDecrypt(ciphertext, key)).toEqual(payload);
		// Same plaintext must not produce the same ciphertext (fresh IV).
		expect(pushEncrypt(payload, key)).not.toBe(ciphertext);
	});

	test("wire format is decryptable by an independent GCM implementation", () => {
		const key = Buffer.from("a".repeat(32)).toString("base64");
		const ciphertext = pushEncrypt(payload, key);
		expect(decryptManually(ciphertext, key)).toEqual(payload);
	});

	test("a different key fails GCM authentication", () => {
		const encryptKey = Buffer.from("k".repeat(32)).toString("base64");
		const wrongKey = Buffer.from("w".repeat(32)).toString("base64");
		const ciphertext = pushEncrypt(payload, encryptKey);
		expect(() => decryptManually(ciphertext, wrongKey)).toThrow();
	});

	test("rejects non-32-byte keys", () => {
		const short = Buffer.from("short").toString("base64");
		expect(() => pushEncrypt(payload, short)).toThrow();
	});
});

describe("ApnsTransport", () => {
	test("POSTs { deviceToken, ciphertext } to the relay with the bearer", async () => {
		const fetchMock = mockFetch();

		const key = Buffer.from("p".repeat(32)).toString("base64");
		const transport = new ApnsTransport({ url: "https://relay.example/", bearer: "sekrit" });
		await transport.deliver("tok-123", key, payload);

		expect(fetchMock.requests).toHaveLength(1);
		const { url, init } = fetchMock.requests[0]!;
		expect(url).toBe("https://relay.example/");
		expect(init.method).toBe("POST");
		expect(init.headers?.authorization).toBe("Bearer sekrit");
		const sent = JSON.parse(init.body!) as { deviceToken: string; ciphertext: string };
		expect(sent.deviceToken).toBe("tok-123");
		expect(decryptManually(sent.ciphertext, key)).toEqual(payload);
	});

	test("omits the bearer when the relay config has none", async () => {
		const fetchMock = mockFetch();
		const transport = new ApnsTransport({ url: "https://relay.example/" });
		await transport.deliver("tok-1", Buffer.from("q".repeat(32)).toString("base64"), payload);
		expect(fetchMock.requests[0]!.init.headers?.authorization).toBeUndefined();
	});

	test("surfaces a non-2xx relay response", async () => {
		const fetchMock = mockFetch(500);
		const transport = new ApnsTransport({ url: "https://relay.example/" });
		await expect(
			transport.deliver("tok-1", Buffer.from("r".repeat(32)).toString("base64"), payload),
		).rejects.toThrow(/500/);
	});
});

describe("Push apns delivery", () => {
	test("register + send routes through the relay with the device's push key", async () => {
		const fetchMock = mockFetch();

		const key = Buffer.from("d".repeat(32)).toString("base64");
		const push = new Push(deviceId => (deviceId === "dev-1" ? key : null), {
			url: "https://relay.example/",
		});
		await push.load();
		await push.register({ deviceId: "dev-1", transport: "apns", target: "apns-token-1" });
		await push.send(payload, "dev-1");

		expect(fetchMock.requests).toHaveLength(1);
		const { init } = fetchMock.requests[0]!;
		const sent = JSON.parse(init.body!) as { deviceToken: string; ciphertext: string };
		expect(sent.deviceToken).toBe("apns-token-1");
		expect(decryptManually(sent.ciphertext, key)).toEqual(payload);
	});

	test("skips delivery when no relay url is configured", async () => {
		const fetchMock = mockFetch();
		const push = new Push(() => Buffer.from("a".repeat(32)).toString("base64"), null);
		await push.load();
		await push.register({ deviceId: "dev-1", transport: "apns", target: "tok" });
		await push.send(payload, "dev-1");
		expect(fetchMock.requests).toHaveLength(0);
	});
});

describe("per-device push key at pairing time", () => {
	test("redeem code issues a 32-byte key stored per device", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "iPhone");
		expect(token).toBeTruthy();
		const device = (await auth.verify(token!))!;
		const key = auth.pushKeyFor(device.id);
		expect(key).toBeTruthy();
		expect(Buffer.from(key!, "base64")).toHaveLength(32);
	});

	test("legacy devices get a key backfilled on load", async () => {
		// Simulate a device record persisted before push keys existed.
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		const token = await auth.redeemCode(code, "OldPhone");
		const device = (await auth.verify(token!))!;
		const legacy = JSON.parse(await Bun.file(join(dir, "auth.json")).text()) as {
			devices: Array<{ id: string; tokenHash: string; name: string; createdAt: string; lastSeenAt: string }>;
		};
		legacy.devices = legacy.devices.map(({ id, tokenHash, name, createdAt, lastSeenAt }) => ({
			id,
			tokenHash,
			name,
			createdAt,
			lastSeenAt,
		}));
		await Bun.write(join(dir, "auth.json"), JSON.stringify(legacy, null, 2));

		const reloaded = new Auth();
		await reloaded.load();
		const key = reloaded.pushKeyFor(device.id);
		expect(key).toBeTruthy();
		expect(Buffer.from(key!, "base64")).toHaveLength(32);
	});

	test("listDevices does not leak push keys", async () => {
		const auth = new Auth();
		await auth.load();
		const code = await auth.issueCode();
		await auth.redeemCode(code, "Phone");
		const devices = auth.listDevices();
		expect(devices).toHaveLength(1);
		expect(devices[0]).not.toHaveProperty("pushKey");
	});
});
