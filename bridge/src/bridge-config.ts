/**
 * Bridge-side configuration (`~/.attache/config.json`, override the directory
 * with `ATTACHE_DIR`). Values are merged over defaults; malformed input falls
 * back to defaults so the bridge always starts.
 */

import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { attacheDir } from "./approvals";

export interface BridgeConfig {
	/** Seconds before an unanswered pending approval is auto-denied. 0 disables. */
	approvalTimeoutSec: number;
	/** APNs relay URL (Tier 3 push); null disables apns-targeted deliveries. */
	apnsRelayUrl: string | null;
	/** Optional bearer for the relay (matches the worker's RELAY_BEARER). */
	apnsRelayBearer: string | null;
}

const CONFIG_FILE = () => join(attacheDir(), "config.json");
const DEFAULTS: BridgeConfig = { approvalTimeoutSec: 300, apnsRelayUrl: null, apnsRelayBearer: null };

export async function loadBridgeConfig(): Promise<BridgeConfig> {
	let parsed: Record<string, unknown> = {};
	try {
		const raw: unknown = JSON.parse(await readFile(CONFIG_FILE(), "utf-8"));
		if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) {
			parsed = raw as Record<string, unknown>;
		}
	} catch {
		// No file or unreadable JSON — defaults apply.
	}
	const timeout = parsed.approvalTimeoutSec;
	const approvalTimeoutSec =
		typeof timeout === "number" && Number.isFinite(timeout) && timeout >= 0
			? timeout
			: DEFAULTS.approvalTimeoutSec;
	const apnsRelayUrl = typeof parsed.apnsRelayUrl === "string" && parsed.apnsRelayUrl.length > 0
		? parsed.apnsRelayUrl
		: DEFAULTS.apnsRelayUrl;
	const apnsRelayBearer = typeof parsed.apnsRelayBearer === "string" && parsed.apnsRelayBearer.length > 0
		? parsed.apnsRelayBearer
		: DEFAULTS.apnsRelayBearer;
	return { approvalTimeoutSec, apnsRelayUrl, apnsRelayBearer };
}
