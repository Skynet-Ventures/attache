/**
 * User-defined projects: named groups of session directories (cwds).
 * Stored bridge-side (~/.attache/projects.json) so every paired device sees
 * the same grouping. Sessions whose cwd is claimed by a project list under it;
 * everything else falls back to auto-grouping by cwd.
 */

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { attacheDir } from "./approvals";

export interface ProjectDef {
	id: string;
	name: string;
	cwds: string[];
	createdAt: string;
}

const PROJECTS_FILE = () => join(attacheDir(), "projects.json");

export class ProjectStore {
	private projects: ProjectDef[] = [];
	private loaded = false;

	async load(): Promise<void> {
		if (this.loaded) return;
		try {
			this.projects = JSON.parse(await readFile(PROJECTS_FILE(), "utf-8")) as ProjectDef[];
		} catch {
			this.projects = [];
		}
		this.loaded = true;
	}

	private async persist(): Promise<void> {
		await mkdir(attacheDir(), { recursive: true });
		await writeFile(PROJECTS_FILE(), JSON.stringify(this.projects, null, 2));
	}

	list(): ProjectDef[] {
		return [...this.projects];
	}

	async create(name: string, cwds: string[] = []): Promise<ProjectDef> {
		const trimmed = name.trim();
		if (!trimmed) throw new Error("Project name cannot be empty");
		if (this.projects.some(p => p.name.toLowerCase() === trimmed.toLowerCase())) {
			throw new Error(`Project "${trimmed}" already exists`);
		}
		const project: ProjectDef = {
			id: crypto.randomUUID(),
			name: trimmed,
			cwds: [...new Set(cwds)],
			createdAt: new Date().toISOString(),
		};
		this.projects.push(project);
		await this.persist();
		return project;
	}

	async rename(id: string, name: string): Promise<ProjectDef> {
		const project = this.projects.find(p => p.id === id);
		if (!project) throw new Error("No such project");
		const trimmed = name.trim();
		if (!trimmed) throw new Error("Project name cannot be empty");
		project.name = trimmed;
		await this.persist();
		return project;
	}

	async remove(id: string): Promise<boolean> {
		const before = this.projects.length;
		this.projects = this.projects.filter(p => p.id !== id);
		if (this.projects.length !== before) {
			await this.persist();
			return true;
		}
		return false;
	}

	/** Claim a cwd for a project (or unassign it from all with projectId null). */
	async assignCwd(cwd: string, projectId: string | null): Promise<void> {
		for (const project of this.projects) {
			project.cwds = project.cwds.filter(c => c !== cwd);
		}
		if (projectId !== null) {
			const project = this.projects.find(p => p.id === projectId);
			if (!project) throw new Error("No such project");
			project.cwds.push(cwd);
		}
		await this.persist();
	}

	/** Which project (if any) claims this cwd? */
	projectFor(cwd: string): ProjectDef | null {
		return this.projects.find(p => p.cwds.includes(cwd)) ?? null;
	}
}
