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
