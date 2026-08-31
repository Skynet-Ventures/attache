/**
 * Drain-of-everything helper for omp's paged `get_messages_page`.
 *
 * omp pagination (see oh-my-pi docs/rpc.md):
 * - success pages carry `messages`, `totalMessages`, and an opaque
 *   `nextCursor` when more messages remain;
 * - `session_busy` (session streaming/compacting) is retried with backoff for
 *   up to ~`maxBusyBackoffMs` of scheduled wait before surfacing;
 * - `stale_cursor` (the snapshot shifted between pages) restarts the walk once
 *   from the beginning, then surfaces the error.
 *
 * The fetch/sleep boundaries are injected so the retry/restart policy can be
 * exercised without a live omp process.
 */

export const MESSAGES_PAGE_LIMIT = 256; // omp's hard cap per page

export interface MessagesPageOk {
	ok: true;
	messages: unknown[];
	totalMessages?: number;
	nextCursor?: string;
}

export interface MessagesPageBusy {
	ok: false;
	error: "session_busy";
}

export interface MessagesPageStale {
	ok: false;
	error: "stale_cursor";
}

export type MessagesPageResult = MessagesPageOk | MessagesPageBusy | MessagesPageStale;

export interface DrainMessagesOptions {
	/** One page at `cursor` (undefined = start). Returns ok/busy/stale. */
	fetchPage(cursor: string | undefined, limit: number): Promise<MessagesPageResult>;
	/** Total scheduled backoff budget for session_busy retries. Default 10_000. */
	maxBusyBackoffMs?: number;
	/** First backoff delay; doubles per retry up to the budget. Default 250. */
	initialBackoffMs?: number;
	/** Sleep implementation, injectable for tests. */
	sleep?: (ms: number) => Promise<void>;
	/** Page cursor to start from; stale_cursor restarts from the beginning. */
	startCursor?: string;
}

/** Test seam mirroring `DrainMessagesOptions` minus the required fetcher. */
export type DrainOverrides = Pick<
	DrainMessagesOptions,
	"maxBusyBackoffMs" | "initialBackoffMs" | "sleep" | "startCursor"
>;

export type DrainMessagesSuccess = { ok: true; messages: unknown[]; totalMessages: number };
export type DrainMessagesResult =
	| DrainMessagesSuccess
	| { ok: false; error: "session_busy" | "stale_cursor" };

export async function drainMessages(opts: DrainMessagesOptions): Promise<DrainMessagesResult> {
	const maxBusy = opts.maxBusyBackoffMs ?? 10_000;
	const sleep = opts.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)));
	const messages: unknown[] = [];
	let cursor: string | undefined = opts.startCursor;
	let totalMessages = 0;
	let restarted = false;
	let scheduledBusyMs = 0;
	let backoffMs = opts.initialBackoffMs ?? 250;

	for (;;) {
		const page = await opts.fetchPage(cursor, MESSAGES_PAGE_LIMIT);
		if (page.ok) {
			messages.push(...page.messages);
			totalMessages = page.totalMessages ?? messages.length;
			if (page.nextCursor && page.nextCursor.length > 0) {
				cursor = page.nextCursor;
				continue;
			}
			return { ok: true, messages, totalMessages };
		}
		if (page.error === "session_busy") {
			if (scheduledBusyMs >= maxBusy) return { ok: false, error: "session_busy" };
			const delay = Math.min(backoffMs, maxBusy - scheduledBusyMs);
			scheduledBusyMs += delay;
			await sleep(delay);
			backoffMs = Math.min(backoffMs * 2, maxBusy);
			continue;
		}
		// stale_cursor: the snapshot shifted mid-walk. Restart from the top once.
		if (restarted) return { ok: false, error: "stale_cursor" };
		restarted = true;
		cursor = undefined;
		messages.length = 0;
		totalMessages = 0;
		scheduledBusyMs = 0;
		backoffMs = opts.initialBackoffMs ?? 250;
	}
}
