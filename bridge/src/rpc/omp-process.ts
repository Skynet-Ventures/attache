/**
 * One spawned `omp --mode rpc` process: request/response correlation,
 * protocol-v2 negotiation, and event fan-out.
 */

import type { Subprocess } from "bun";
import { RpcFrameDecoder } from "./frames";
import type { RpcFrame, RpcResponseFrame } from "../types";

export interface OmpSpawnOptions {
	cwd?: string;
	/** Resume target passed to `-r` (path or id prefix). */
	resume?: string;
	ompBin?: string;
	extraArgs?: string[];
}

interface Pending {
	resolve: (frame: RpcResponseFrame) => void;
	reject: (err: Error) => void;
	command: string;
}

export type FrameListener = (frame: RpcFrame) => void;

export class OmpProcess {
	private proc: Subprocess<"pipe", "pipe", "pipe"> | null = null;
	private readonly decoder = new RpcFrameDecoder();
	private readonly pending = new Map<string, Pending>();
	private readonly listeners = new Set<FrameListener>();
	private reqCounter = 0;
	private stderrTail = "";
	ready = false;
	exited: Promise<number> | null = null;
	onExit: ((code: number) => void) | null = null;

	constructor(private readonly opts: OmpSpawnOptions = {}) {}

	async start(): Promise<void> {
		const bin = this.opts.ompBin ?? "omp";
		const args = [bin, "--mode", "rpc"];
		if (this.opts.cwd) args.push("--cwd", this.opts.cwd);
		if (this.opts.resume) args.push("-r", this.opts.resume);
		if (this.opts.extraArgs) args.push(...this.opts.extraArgs);

		const proc = Bun.spawn(args, {
			cwd: this.opts.cwd,
			stdin: "pipe",
			stdout: "pipe",
			stderr: "pipe",
			env: { ...process.env, PI_RPC_EMIT_TITLE: "1" },
		});
		this.proc = proc;
		this.exited = proc.exited.then(code => {
			this.failAllPending(new Error(`omp exited (code ${code}). ${this.stderrTail.slice(-400)}`));
			this.onExit?.(code);
			return code;
		});

		void this.pumpStdout(proc.stdout);
		void this.pumpStderr(proc.stderr);

		await this.waitForReady();
		// Opt in to lossless framing for oversized events.
		try {
			await this.request({ type: "negotiate_protocol", protocolVersion: 2 });
		} catch {
			// v1 fallback is acceptable; oversized frames degrade per spec.
		}
	}

	subscribe(listener: FrameListener): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	/** Send a correlated command and await its response frame. */
	request(command: Record<string, unknown>, timeoutMs = 120_000): Promise<RpcResponseFrame> {
		const id = `br_${++this.reqCounter}`;
		const frame = { id, ...command };
		return new Promise<RpcResponseFrame>((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				reject(new Error(`omp rpc timeout for ${String(command.type)}`));
			}, timeoutMs);
			this.pending.set(id, {
				command: String(command.type),
				resolve: f => {
					clearTimeout(timer);
					resolve(f);
				},
				reject: e => {
					clearTimeout(timer);
					reject(e);
				},
			});
			this.write(frame);
		});
	}

	/** Fire-and-forget frame (extension_ui_response, host_tool_result, ...). */
	write(frame: Record<string, unknown>): void {
		const proc = this.proc;
		if (!proc || !proc.stdin) throw new Error("omp process not running");
		proc.stdin.write(`${JSON.stringify(frame)}\n`);
		proc.stdin.flush();
	}

	dispose(): void {
		try {
			this.proc?.stdin?.end();
		} catch {
			/* already closed */
		}
		const proc = this.proc;
		if (proc) {
			// Give omp a moment to drain, then make sure it is gone.
			setTimeout(() => {
				try {
					proc.kill();
				} catch {
					/* already dead */
				}
			}, 3_000);
		}
	}

	private async waitForReady(): Promise<void> {
		if (this.ready) return;
		await new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error("omp did not emit ready frame")), 30_000);
			const off = this.subscribe(frame => {
				if (frame.type === "ready") {
					this.ready = true;
					clearTimeout(timer);
					off();
					resolve();
				}
			});
		});
	}

	private async pumpStdout(stream: ReadableStream<Uint8Array>): Promise<void> {
		const textDecoder = new TextDecoder();
		for await (const raw of stream) {
			for (const frame of this.decoder.push(textDecoder.decode(raw, { stream: true }))) {
				this.dispatch(frame);
			}
		}
	}

	private async pumpStderr(stream: ReadableStream<Uint8Array>): Promise<void> {
		const textDecoder = new TextDecoder();
		for await (const raw of stream) {
			this.stderrTail = (this.stderrTail + textDecoder.decode(raw, { stream: true })).slice(-4_000);
		}
	}

	private dispatch(frame: RpcFrame): void {
		if (frame.type === "response") {
			const res = frame as RpcResponseFrame;
			if (res.id && this.pending.has(res.id)) {
				const p = this.pending.get(res.id)!;
				this.pending.delete(res.id);
				p.resolve(res);
				// `prompt` acks also matter to listeners (agentInvoked); fall through.
			}
		}
		for (const listener of this.listeners) {
			try {
				listener(frame);
			} catch (err) {
				console.error("[omp-process] listener error", err);
			}
		}
	}

	private failAllPending(err: Error): void {
		for (const [, p] of this.pending) p.reject(err);
		this.pending.clear();
	}
}
