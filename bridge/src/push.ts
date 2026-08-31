/**
 * Offline notification dispatch.
 *
 * While the app holds a WebSocket, it renders its own local notifications.
 * When no client is connected, the bridge pushes through whichever transports
 * devices registered:
 *
 *  - "webhook": POST the payload to a user-supplied URL (ntfy.sh topic, a
 *    Shortcut webhook, anything on the tailnet). Zero third-party defaults.
 *  - "apns": reserved for the App Store build's stateless relay
 *    (docs/notifications.md); not implemented in v1.
 */

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attacheDir } from "./approvals";

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
	private targets: PushTarget[] = [];

	async load(): Promise<void> {
		try {
			this.targets = JSON.parse(await readFile(PUSH_FILE(), "utf-8")) as PushTarget[];
		} catch {
			this.targets = [];
		}
	}

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
			}
			// "apns": intentionally unimplemented in v1 — see docs/notifications.md.
		}
	}
}
