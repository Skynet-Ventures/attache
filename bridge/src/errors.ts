import type { ErrorCode } from "./types";

/**
 * An RPC failure that carries a machine-readable code on the result frame
 * (protocol_mismatch, revoked, session_busy, stale_cursor). Plain Errors
 * surface description-only failures.
 */
export class ProtocolError extends Error {
	constructor(
		readonly code: ErrorCode,
		message: string,
	) {
		super(message);
		this.name = "ProtocolError";
	}
}
