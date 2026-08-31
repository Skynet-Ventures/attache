/**
 * Read/write access to omp's global config (`~/.omp/agent/config.yml`) for the
 * roles & settings screen. Writes are surgical: we parse, mutate the specific
 * key, and re-serialize with the `yaml` package (comment preservation is not
 * guaranteed — the bridge makes a timestamped backup before the first write of
 * each run).
 */

import { copyFile, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import YAML from "yaml";
import { ompAgentDir } from "./sessions/store";
import type { ApprovalMode, ThinkingLevel } from "./types";

export interface RoleEntry {
	role: string;
	model: string;
	thinkingLevel: ThinkingLevel | null;
}

const CONFIG_PATH = () => join(ompAgentDir(), "config.yml");
let backedUpThisRun = false;

async function readConfig(): Promise<Record<string, any>> {
	try {
		return (YAML.parse(await readFile(CONFIG_PATH(), "utf-8")) as Record<string, any>) ?? {};
	} catch {
		return {};
	}
}

async function writeConfig(config: Record<string, any>): Promise<void> {
	if (!backedUpThisRun) {
		try {
			const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, "");
			await copyFile(CONFIG_PATH(), `${CONFIG_PATH()}.bak-attache-${stamp}`);
		} catch {
			/* no existing config to back up */
		}
		backedUpThisRun = true;
	}
	await writeFile(CONFIG_PATH(), YAML.stringify(config));
}

function splitSelector(selector: string): { model: string; thinkingLevel: ThinkingLevel | null } {
	const match = selector.match(/^(.*?):(off|minimal|low|medium|high|xhigh|max)$/);
	if (match) return { model: match[1] ?? selector, thinkingLevel: match[2] as ThinkingLevel };
	return { model: selector, thinkingLevel: null };
}

export async function getRoles(): Promise<RoleEntry[]> {
	const config = await readConfig();
	const roles = (config.modelRoles ?? {}) as Record<string, string>;
	return Object.entries(roles).map(([role, selector]) => ({
		role,
		...splitSelector(String(selector)),
	}));
}

export async function setRole(
	role: string,
	model: string | undefined,
	thinkingLevel: ThinkingLevel | null | undefined,
): Promise<RoleEntry[]> {
	const config = await readConfig();
	config.modelRoles ??= {};
	const current = splitSelector(String(config.modelRoles[role] ?? ""));
	const nextModel = model ?? current.model;
	const nextLevel = thinkingLevel === undefined ? current.thinkingLevel : thinkingLevel;
	if (!nextModel) throw new Error(`Role ${role} has no model configured`);
	config.modelRoles[role] = nextLevel ? `${nextModel}:${nextLevel}` : nextModel;
	await writeConfig(config);
	return getRoles();
}

export async function getApprovalMode(): Promise<ApprovalMode | null> {
	const config = await readConfig();
	return (config.tools?.approvalMode as ApprovalMode) ?? null;
}

export async function setApprovalModeGlobal(mode: ApprovalMode): Promise<void> {
	const config = await readConfig();
	config.tools ??= {};
	config.tools.approvalMode = mode;
	await writeConfig(config);
}

export async function getEnabledModels(): Promise<string[]> {
	const config = await readConfig();
	return (config.enabledModels as string[]) ?? [];
}

/**
 * Real values for the settings screen's environment rows: MCP servers,
 * skills, extensions, compaction, and any configured fallback chains.
 */
export const TASK_ISOLATION_MODES = [
	"none", "auto", "apfs", "btrfs", "zfs", "reflink",
	"overlayfs", "projfs", "block-clone", "rcopy",
] as const;

export async function getTaskIsolationMode(): Promise<string> {
	const config = await readConfig();
	return String(config.task?.isolation?.mode ?? "none");
}

export async function setTaskIsolationMode(mode: string): Promise<void> {
	if (!TASK_ISOLATION_MODES.includes(mode as (typeof TASK_ISOLATION_MODES)[number])) {
		throw new Error(`invalid isolation mode: ${mode}`);
	}
	const config = await readConfig();
	config.task ??= {};
	config.task.isolation ??= {};
	config.task.isolation.mode = mode;
	await writeConfig(config);
}

export async function getOmpSummary(): Promise<Record<string, unknown>> {
	const config = await readConfig();
	const agentDir = ompAgentDir();

	const countEntries = async (dir: string): Promise<number> => {
		try {
			const { readdir } = await import("node:fs/promises");
			return (await readdir(dir)).filter(e => !e.startsWith(".")).length;
		} catch {
			return 0;
		}
	};

	// MCP servers may be declared under a few keys depending on omp version.
	const mcp = (config.mcp?.servers ?? config.mcpServers ?? {}) as Record<string, unknown>;
	const mcpCount = typeof mcp === "object" ? Object.keys(mcp).length : 0;

	// Fallback chains: any modelRoles value that is a list.
	const fallbacks: Record<string, string[]> = {};
	for (const [role, value] of Object.entries((config.modelRoles ?? {}) as Record<string, unknown>)) {
		if (Array.isArray(value) && value.length > 1) fallbacks[role] = value.map(String);
	}

	const compaction = (config.compaction ?? {}) as Record<string, unknown>;
	const threshold =
		typeof compaction.threshold === "number"
			? compaction.threshold
			: typeof compaction.triggerRatio === "number"
				? compaction.triggerRatio
				: 0.85;

	return {
		mcpServers: mcpCount,
		skills: await countEntries(join(agentDir, "skills")),
		extensions: await countEntries(join(agentDir, "extensions")),
		agents: await countEntries(join(agentDir, "agents")),
		snapcompact: {
			enabled: compaction.enabled !== false,
			threshold,
		},
		fallbacks,
		hindsight: config.hindsight?.enabled ?? config.memory?.enabled ?? null,
		taskIsolation: String(config.task?.isolation?.mode ?? "none"),
	};
}
