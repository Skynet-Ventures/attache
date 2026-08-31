/**
 * NDJSON framing for omp RPC stdout, including protocol-v2 `rpc_chunk`
 * reassembly (see oh-my-pi docs/rpc.md "Transport and Framing").
 */

import type { RpcChunkFrame, RpcFrame } from "../types";

const DEFAULT_REASSEMBLY_LIMIT = 64 * 1024 * 1024;

export class RpcFrameDecoder {
	private buffer = "";
	private chunkId: string | null = null;
	private chunkParts: Uint8Array[] = [];
	private chunkExpected = 0;
	private chunkBytes = 0;
	private chunkDeclaredBytes = 0;

	constructor(private readonly maxReassembledBytes = DEFAULT_REASSEMBLY_LIMIT) {}

	/** Feed raw stdout text; returns fully decoded logical frames. */
	push(text: string): RpcFrame[] {
		this.buffer += text;
		const frames: RpcFrame[] = [];
		let idx: number;
		while ((idx = this.buffer.indexOf("\n")) >= 0) {
			const line = this.buffer.slice(0, idx).trim();
			this.buffer = this.buffer.slice(idx + 1);
			if (!line) continue;
			let obj: RpcFrame;
			try {
				obj = JSON.parse(line) as RpcFrame;
			} catch {
				// Not fatal: omp guarantees one JSON object per line, but a
				// crashed process can leave a torn tail. Skip it.
				continue;
			}
			const out = this.accept(obj);
			if (out) frames.push(out);
		}
		return frames;
	}

	private accept(frame: RpcFrame): RpcFrame | null {
		if (frame.type === "rpc_chunk") {
			return this.acceptChunk(frame as RpcChunkFrame);
		}
		if (this.chunkId !== null) {
			// Interleaved non-chunk frame inside a chunk sequence: the spec says
			// reject the sequence. Drop the partial chunk, deliver this frame.
			this.resetChunks();
		}
		return frame;
	}

	private acceptChunk(chunk: RpcChunkFrame): RpcFrame | null {
		if (this.chunkId === null) {
			if (chunk.index !== 0) return null; // mid-sequence garbage
			if (chunk.byteLength > this.maxReassembledBytes) return null;
			this.chunkId = chunk.chunkId;
			this.chunkExpected = chunk.count;
			this.chunkDeclaredBytes = chunk.byteLength;
			this.chunkParts = [];
			this.chunkBytes = 0;
		} else if (chunk.chunkId !== this.chunkId || chunk.index !== this.chunkParts.length) {
			this.resetChunks();
			return null;
		}
		const bytes = Uint8Array.from(atob(chunk.data), c => c.charCodeAt(0));
		this.chunkParts.push(bytes);
		this.chunkBytes += bytes.byteLength;
		if (this.chunkBytes > this.maxReassembledBytes) {
			this.resetChunks();
			return null;
		}
		if (this.chunkParts.length < this.chunkExpected) return null;

		const whole = new Uint8Array(this.chunkBytes);
		let off = 0;
		for (const part of this.chunkParts) {
			whole.set(part, off);
			off += part.byteLength;
		}
		this.resetChunks();
		if (this.chunkDeclaredBytes !== 0 && whole.byteLength !== this.chunkDeclaredBytes) {
			// byteLength mismatch: reject per spec.
			return null;
		}
		try {
			return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(whole)) as RpcFrame;
		} catch {
			return null;
		}
	}

	private resetChunks(): void {
		this.chunkId = null;
		this.chunkParts = [];
		this.chunkExpected = 0;
		this.chunkBytes = 0;
		this.chunkDeclaredBytes = 0;
	}
}
