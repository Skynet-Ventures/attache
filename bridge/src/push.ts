/**
 * Offline notification dispatch.
 *
 * While the app holds a WebSocket, it renders its own local notifications.
 * When no client is connected, the bridge pushes through whichever transports
 * devices registered:
 *
 *  - "webhook": POST the payload to a user-supplied URL (ntfy.sh topic, a
 *    Shortcut webhook, anything on the tailnet). Zero third-party defaults.
 *  - "apns": encrypt the payload with the device's push key (exchanged at
 *    pairing time) and POST `{ deviceToken, ciphertext }` to the configured
 *    stateless relay (see docs/notifications.md). The relay forwards to APNs
 *    and never sees the plaintext.
 */

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attacheDir } from "./approvals";

const GCM_IV_LENGTH = 12;
const GCM_TAG_LENGTH = 16;

export interface PushTarget {
	deviceId: string;
	transport: "webhook" | "apns";
	target: string; // URL for webhook, device token for apns
}

export interface PushPayload {
	kind: "approval" | "turn_done" | "goal_done" | "advisor" | "error";
	title: string;
	body: string;
	sessionId: string;
	approvalId?: string;
}

const PUSH_FILE = () => join(attacheDir(), "push.json");

export class Push {
	constructor(
		private readonly pushKeyFor: (deviceId: string) => string | null = () => null,
		private apnsRelay: ApnsRelayConfig | null = null,
	) {}

	async load(): Promise<void> {
		try {
			this.targets = JSON.parse(await readFile(PUSH_FILE(), "utf-8")) as PushTarget[];
		} catch {
			this.targets = [];
		}
	}

	/** Configure the stateless APNs relay (from bridge config). */
	setApnsRelay(config: ApnsRelayConfig | null): void {
		this.apnsRelay = config;
	}

	private targets: PushTarget[] = [];

	/** Register, replace, or (with an empty target) remove a device's target. */
	async register(target: PushTarget): Promise<void> {
		this.targets = this.targets.filter(
			t => !(t.deviceId === target.deviceId && t.transport === target.transport),
		);
		if (target.target.trim().length > 0) this.targets.push(target);
		await mkdir(attacheDir(), { recursive: true });
		await writeFile(PUSH_FILE(), JSON.stringify(this.targets, null, 2));
	}

	targetFor(deviceId: string): PushTarget | undefined {
		return this.targets.find(t => t.deviceId === deviceId);
	}

	async send(payload: PushPayload, onlyDeviceId?: string): Promise<void> {
		for (const target of this.targets) {
			if (onlyDeviceId && target.deviceId !== onlyDeviceId) continue;
			if (target.transport === "webhook") {
				try {
					await fetch(target.target, {
						method: "POST",
						headers: {
							"content-type": "application/json",
							// ntfy.sh conveniences; harmless for generic webhooks.
							title: payload.title,
							priority: payload.kind === "approval" ? "high" : "default",
							tags: payload.kind === "approval" ? "warning" : "robot",
						},
						body: JSON.stringify(payload),
						signal: AbortSignal.timeout(10_000),
					});
				} catch (err) {
					console.error(`[push] webhook delivery failed: ${String(err)}`);
				}
				continue;
			}
			if (target.transport === "apns") {
				const pushKey = this.pushKeyFor(target.deviceId);
				if (!this.apnsRelay) {
					console.error("[push] apns target registered but no apnsRelayUrl configured");
					continue;
				}
				if (!pushKey) {
					console.error(`[push] apns delivery failed: no push key for device ${target.deviceId}`);
					continue;
				}
				try {
					await new ApnsTransport(this.apnsRelay).deliver(target.target, pushKey, payload);
				} catch (err) {
					console.error(`[push] apns delivery failed: ${String(err)}`);
				}
				continue;
			}
		}
	}
}

// ---------------------------------------------------------------------------
// APNs relay transport (Tier 3)
// ---------------------------------------------------------------------------

export interface ApnsRelayConfig {
	url: string;
	bearer?: string;
}

/**
 * Encrypts a push payload for a device's push key (AES-256-GCM, 12-byte IV
 * prepended, 16-byte auth tag appended — all base64). Only the relay's
 * recipient (the app's notification service extension) holds the key, so the
 * relay cannot read approval contents.
 */
export function pushEncrypt(payload: unknown, pushKeyBase64: string): string {
	const key = Buffer.from(pushKeyBase64, "base64");
	if (key.byteLength !== 32) throw new Error("push key must be 32 bytes");
	const iv = randomBytes(GCM_IV_LENGTH);
	const cipher = createCipheriv("aes-256-gcm", key, iv);
	const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), "utf8"), cipher.final()]);
	const tag = cipher.getAuthTag();
	return Buffer.concat([iv, ciphertext, tag]).toString("base64");
}

/** Inverse of {@link pushEncrypt}; shared with the app via the same format. */
export function pushDecrypt(ciphertextBase64: string, pushKeyBase64: string): unknown {
	const key = Buffer.from(pushKeyBase64, "base64");
	if (key.byteLength !== 32) throw new Error("push key must be 32 bytes");
	const data = Buffer.from(ciphertextBase64, "base64");
	if (data.byteLength < GCM_IV_LENGTH + GCM_TAG_LENGTH) throw new Error("ciphertext too short");
	const iv = data.subarray(0, GCM_IV_LENGTH);
	const ciphertext = data.subarray(GCM_IV_LENGTH, data.byteLength - GCM_TAG_LENGTH);
	const tag = data.subarray(data.byteLength - GCM_TAG_LENGTH);
	const decipher = createDecipheriv("aes-256-gcm", key, iv);
	decipher.setAuthTag(tag);
	const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
	return JSON.parse(plaintext.toString("utf8"));
}

/**
 * Posts `{ deviceToken, ciphertext }` to the stateless relay. The relay holds
 * the APNs signing key, validates the shared bearer, and forwards the
 * ciphertext to APNs without storing anything.
 */
export class ApnsTransport {
	constructor(private readonly relay: ApnsRelayConfig) {}

	async deliver(deviceToken: string, pushKey: string, payload: PushPayload): Promise<void> {
		const ciphertext = pushEncrypt(payload, pushKey);
		const headers: Record<string, string> = { "content-type": "application/json" };
		if (this.relay.bearer) headers.authorization = `Bearer ${this.relay.bearer}`;
		const res = await fetch(this.relay.url, {
			method: "POST",
			headers,
			body: JSON.stringify({ deviceToken, ciphertext }),
			signal: AbortSignal.timeout(10_000),
		});
		if (!res.ok) throw new Error(`relay returned HTTP ${res.status}`);
	}
}
