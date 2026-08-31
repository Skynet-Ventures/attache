/**
 * Per-pending-approval timeout. When an approval is not resolved by the app
 * within the configured budget, the bridge answers omp with Deny and reports
 * `approval_resolved { by: "timeout" }`. A non-positive budget disables the
 * timer (0 = never auto-deny).
 */
export class ApprovalTimer {
	private readonly timers = new Map<string, ReturnType<typeof setTimeout>>();

	constructor(
		private readonly timeoutMs: number,
		private readonly onTimeout: (approvalId: string) => void,
	) {}

	/** Arm the timer for a pending approval. No-op for disabled/duplicate ids. */
	start(approvalId: string): void {
		if (this.timeoutMs <= 0 || this.timers.has(approvalId)) return;
		const timer = setTimeout(() => {
			this.timers.delete(approvalId);
			this.onTimeout(approvalId);
		}, this.timeoutMs);
		this.timers.set(approvalId, timer);
	}

	/** Cancel a pending timer; safe to call for unknown ids. */
	cancel(approvalId: string): void {
		const timer = this.timers.get(approvalId);
		if (timer === undefined) return;
		clearTimeout(timer);
		this.timers.delete(approvalId);
	}

	/** Cancel every outstanding timer (session teardown). */
	clear(): void {
		for (const timer of this.timers.values()) clearTimeout(timer);
		this.timers.clear();
	}
}
