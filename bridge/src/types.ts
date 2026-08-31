/**
 * Attaché bridge protocol types (v1).
 *
 * Authoritative spec: docs/protocol.md. The Swift models in
 * ios/Attache/Models/Protocol.swift mirror these shapes.
 */

export const PROTOCOL_VERSION = 1;

/** Machine-readable error codes on bridge result frames. */
export type ErrorCode =
	| "protocol_mismatch"
	| "revoked"
	| "session_busy"
	| "stale_cursor"
	| "too_large"
	| "unknown_session";

// ---------------------------------------------------------------------------
// omp RPC wire types (subset we consume; see oh-my-pi docs/rpc.md)
// ---------------------------------------------------------------------------

export interface RpcReadyFrame {
	type: "ready";
	protocolVersion: number;
	supportedProtocolVersions?: number[];
	maxFrameBytes?: number;
	maxReassembledFrameBytes?: number;
}

export interface RpcChunkFrame {
	type: "rpc_chunk";
	chunkId: string;
	index: number;
	count: number;
	byteLength: number;
	data: string; // base64 segment
}

export interface RpcResponseFrame {
	type: "response";
	id?: string;
	command: string;
	success: boolean;
	data?: unknown;
	error?: string;
	code?: string;
}

export interface RpcExtensionUIRequest {
	type: "extension_ui_request";
	id: string;
	method:
		| "select"
		| "confirm"
		| "input"
		| "editor"
		| "cancel"
		| "notify"
		| "setStatus"
		| "setWidget"
		| "setTitle"
		| "set_editor_text"
		| "open_url";
	title?: string;
	message?: string;
	options?: string[];
	optionDetails?: Array<{ description?: string }>;
	placeholder?: string;
	timeout?: number;
	notifyType?: "info" | "warning" | "error";
	statusKey?: string;
	statusText?: string;
	url?: string;
	[key: string]: unknown;
}

export type RpcFrame =
	| RpcReadyFrame
	| RpcChunkFrame
	| RpcResponseFrame
	| RpcExtensionUIRequest
	| { type: string; [key: string]: unknown };

// ---------------------------------------------------------------------------
// Bridge <-> app protocol
// ---------------------------------------------------------------------------

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type ApprovalMode = "always-ask" | "write" | "yolo";
export type Verdict = "allow" | "allow_always" | "deny";
export type PromptMode = "chat" | "plan" | "goal" | "loop";
export type SteeringMode = "all" | "one-at-a-time";
export type InterruptMode = "immediate" | "wait";

/**
 * The scope an always-allow rule applies to. Legacy rules (no `scope` field)
 * are treated as `{ kind: "global" }` for back-compat.
 */
export type RuleScope =
	| { kind: "global" }
	| { kind: "cwd"; cwd: string }
	| { kind: "session"; sessionId: string };

export interface ClientCommand {
	id?: string;
	type: string;
	[key: string]: unknown;
}

export interface ResultFrame {
	type: "result";
	id?: string;
	ok: boolean;
	data?: unknown;
	error?: string;
	code?: ErrorCode;
}

export interface DeviceInfo {
	deviceId: string;
	name: string;
	createdAt: string;
	lastSeen?: string;
}

export interface MachineInfo {
	name: string;
	host: string;
	bridgeVersion: string;
	ompVersion: string;
	platform: string;
	uptimeSec: number;
}

export interface SessionSummary {
	/** Bridge session id for live sessions, jsonl path stem otherwise. */
	id: string;
	title: string;
	project: string;
	cwd: string;
	sessionPath: string;
	updatedAt: string;
	live: boolean;
	status: "running" | "waiting" | "idle";
	shortId: string;
}

export interface ProjectGroup {
	/** Custom project id, or "auto:<cwd>" for derived groups. */
	id: string;
	name: string;
	cwd: string;
	custom: boolean;
	sessions: SessionSummary[];
}

export interface ContextUsage {
	tokens: number;
	contextWindow: number;
	percent: number;
}

export interface SessionState {
	sessionId: string;
	sessionName: string;
	sessionFile: string;
	cwd: string;
	model: { provider: string; id: string };
	thinkingLevel: ThinkingLevel;
	isStreaming: boolean;
	isCompacting: boolean;
	contextUsage: ContextUsage | null;
	costUsd: number | null;
	turn: number;
	messageCount: number;
	queuedMessageCount: number;
	approvalMode: ApprovalMode | null;
	fastModeEnabled: boolean;
	fastModeActive: boolean;
	steeringMode: SteeringMode;
	followUpMode: SteeringMode;
	interruptMode: InterruptMode;
	todoPhases: unknown[];
}

export interface ApprovalRequest {
	id: string;
	sessionId: string;
	tool: string;
	/** Full prompt text from omp ("Allow tool: bash\n..."). */
	prompt: string;
	command: string | null;
	reason: string | null;
	risk: "high" | "medium" | "low";
	createdAt: string;
	options: string[];
}

export interface AdvisorNote {
	sessionId: string;
	advisor: string;
	severity: "nit" | "concern" | "blocker";
	text: string;
	timestamp: string;
}

export interface AlwaysRule {
	id: string;
	tool: string;
	/** Normalized command prefix (bash) or exact tool name match. */
	pattern: string | null;
	createdAt: string;
	note: string;
	/** Which sessions the rule applies to; defaults to global for legacy rules. */
	scope: RuleScope;
}

// ---------------------------------------------------------------------------
// Cost summary (get_cost_summary)
// ---------------------------------------------------------------------------

export interface CostDay {
	/** Local calendar date, YYYY-MM-DD. */
	date: string;
	costUSD: number;
	tokensIn: number;
	tokensOut: number;
	/** Distinct sessions with metered usage on this date. */
	sessions: number;
}

export interface CostByProject {
	/** Custom project id when the session cwd is claimed, null otherwise. */
	projectId: string | null;
	cwd: string;
	costUSD: number;
	/** Distinct sessions with metered usage in this project. */
	sessions: number;
}

export interface CostSummary {
	days: CostDay[];
	byProject: CostByProject[];
}

export type ServerEvent =
	| ResultFrame
	| { type: "machine_info"; machine: MachineInfo }
	| { type: "session_state"; state: SessionState }
	| { type: "stream"; sessionId: string; seq: number; event: Record<string, unknown> }
	| { type: "approval_request"; approval: ApprovalRequest }
	| {
			type: "approval_resolved";
			sessionId: string;
			approvalId: string;
			verdict: Verdict | "deny" | "allow";
			by: "app" | "tui" | "rule" | "timeout" | "mode";
			ruleNote?: string;
	  }
	| { type: "subagent"; sessionId: string; kind: string; frame: Record<string, unknown> }
	| { type: "advisor"; note: AdvisorNote }
	| { type: "sessions_changed" }
	| { type: "commands"; sessionId: string; commands: unknown }
	| { type: "bye"; reason: string };
