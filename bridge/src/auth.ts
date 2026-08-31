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
	createdAt: string;
	lastSeenAt: string;
}

interface AuthState {
	devices: DeviceToken[];
}

const AUTH_FILE = () => join(attacheDir(), "auth.json");
// Unambiguous alphabet (no 0/O, 1/I/L).
const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
const CODE_TTL_MS = 5 * 60 * 1000;

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
	}

	private async persist(): Promise<void> {
		await mkdir(attacheDir(), { recursive: true });
		await writeFile(AUTH_FILE(), JSON.stringify(this.state, null, 2));
	}

	/** Generate (or return the still-valid) pairing code. */
	issueCode(): string {
		if (this.activeCode && this.activeCode.expiresAt > Date.now()) {
			return this.activeCode.code;
		}
		const bytes = crypto.getRandomValues(new Uint8Array(8));
		const code = [...bytes].map(b => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
		this.activeCode = { code, expiresAt: Date.now() + CODE_TTL_MS };
		return code;
	}

	get codeActive(): boolean {
		return !!this.activeCode && this.activeCode.expiresAt > Date.now();
	}

	async redeemCode(code: string, deviceName: string): Promise<string | null> {
		if (!this.activeCode || this.activeCode.expiresAt < Date.now()) return null;
		if (code.trim().toUpperCase() !== this.activeCode.code) return null;
		this.activeCode = null; // single use
		const tokenBytes = crypto.getRandomValues(new Uint8Array(32));
		const token = [...tokenBytes].map(b => b.toString(16).padStart(2, "0")).join("");
		this.state.devices.push({
			id: crypto.randomUUID(),
			name: deviceName || "iOS device",
			tokenHash: await sha256Hex(token),
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

	listDevices(): Array<Omit<DeviceToken, "tokenHash">> {
		return this.state.devices.map(({ tokenHash: _hash, ...rest }) => rest);
	}
}
