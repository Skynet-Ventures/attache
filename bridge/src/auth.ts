/**
 * Pairing codes and bearer tokens. State lives in ~/.attache/auth.json.
 *
 * Pairing: `attache-bridge serve` (or `pair`) prints an 8-char code; the app
 * POSTs it to /pair within 5 minutes and receives a long-lived token. Tokens
 * are random 256-bit values; we store only their SHA-256 hashes.
 */

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attacheDir } from "./approvals";

interface DeviceToken {
	id: string;
	name: string;
	tokenHash: string;
	/** Base64 32-byte AES-256 key for APNs payload encryption; backfilled for legacy devices. */
	pushKey: string;
	createdAt: string;
	lastSeenAt: string;
}

interface AuthState {
	devices: DeviceToken[];
	/** Persisted so a separate `attache-bridge pair` process can read it back. */
	activeCode?: { code: string; expiresAt: number } | null;
}

const AUTH_FILE = () => join(attacheDir(), "auth.json");
// Unambiguous alphabet (no 0/O, 1/I/L).
const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
const CODE_TTL_MS = 5 * 60 * 1000;

/** Fresh per-device AES-256 key for APNs payload encryption (base64). */
function newPushKey(): string {
	return Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64");
}

async function sha256Hex(text: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
	return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("");
}

export class Auth {
	private state: AuthState = { devices: [] };
	private activeCode: { code: string; expiresAt: number } | null = null;

	async load(): Promise<void> {
		try {
			this.state = JSON.parse(await readFile(AUTH_FILE(), "utf-8")) as AuthState;
		} catch {
			this.state = { devices: [] };
		}
		// Devices paired before APNs support have no push key. Backfill one so
		// every device can receive encrypted pushes without re-pairing.
		let backfilled = false;
		for (const device of this.state.devices) {
			if (typeof device.pushKey !== "string" || device.pushKey.length === 0) {
				device.pushKey = newPushKey();
				backfilled = true;
			}
		}
		if (backfilled) await this.persist();
		this.activeCode = this.state.activeCode ?? null;
	}

	private async persist(): Promise<void> {
		await mkdir(attacheDir(), { recursive: true });
		await writeFile(AUTH_FILE(), JSON.stringify(this.state, null, 2));
	}

	/** Generate (or return the still-valid) pairing code, persisted to disk. */
	async issueCode(): Promise<string> {
		if (this.activeCode && this.activeCode.expiresAt > Date.now()) {
			return this.activeCode.code;
		}
		const bytes = crypto.getRandomValues(new Uint8Array(8));
		const code = [...bytes].map(b => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
		const active = { code, expiresAt: Date.now() + CODE_TTL_MS };
		this.activeCode = active;
		this.state.activeCode = active;
		await this.persist();
		return code;
	}

	get codeActive(): boolean {
		return !!this.activeCode && this.activeCode.expiresAt > Date.now();
	}

	/** The pairing code last persisted by a running bridge, if still valid. */
	get persistedCode(): string | null {
		if (!this.state.activeCode || this.state.activeCode.expiresAt <= Date.now()) return null;
		return this.state.activeCode.code;
	}

	async redeemCode(code: string, deviceName: string): Promise<string | null> {
		if (!this.activeCode || this.activeCode.expiresAt < Date.now()) return null;
		if (code.trim().toUpperCase() !== this.activeCode.code) return null;
		this.activeCode = null; // single use
		this.state.activeCode = null; // single use, persisted
		const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
		const token = [...tokenBytes].map(b => b.toString(16).padStart(2, "0")).join("");
		this.state.devices.push({
			id: crypto.randomUUID(),
			name: deviceName || "iOS device",
			tokenHash: await sha256Hex(token),
			pushKey: newPushKey(),
			createdAt: new Date().toISOString(),
			lastSeenAt: new Date().toISOString(),
		});
		await this.persist();
		return token;
	}

	async verify(token: string | null | undefined): Promise<DeviceToken | null> {
		if (!token) return null;
		const hash = await sha256Hex(token);
		const device = this.state.devices.find(d => d.tokenHash === hash) ?? null;
		if (device) {
			device.lastSeenAt = new Date().toISOString();
			void this.persist();
		}
		return device;
	}

	async revoke(deviceId: string): Promise<boolean> {
		const before = this.state.devices.length;
		this.state.devices = this.state.devices.filter(d => d.id !== deviceId);
		if (this.state.devices.length !== before) {
			await this.persist();
			return true;
		}
		return false;
	}

	listDevices(): Array<Omit<DeviceToken, "tokenHash" | "pushKey">> {
		return this.state.devices.map(({ tokenHash: _hash, pushKey: _key, ...rest }) => rest);
	}

	/** The device's APNs encryption key, or null if the device is unknown. */
	pushKeyFor(deviceId: string): string | null {
		return this.state.devices.find(d => d.id === deviceId)?.pushKey ?? null;
	}
}
