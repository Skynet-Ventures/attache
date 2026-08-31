# Attaché bridge protocol (v1)

The iOS app never talks to `omp` directly — `omp` only speaks newline-delimited
JSON over stdio (`omp --mode rpc`). The **bridge** (`attache-bridge`) runs on the
machine that runs omp, owns the omp processes, and exposes this protocol to the
app over HTTP + WebSocket. On a Tailscale network you connect straight to the
bridge's tailnet address; nothing is relayed through third parties.

```
┌────────────┐   WebSocket (this doc)   ┌────────────────┐   NDJSON stdio   ┌─────┐
│ Attaché iOS│ ◄══════════════════════► │ attache-bridge │ ◄══════════════► │ omp │
└────────────┘        Tailscale         └────────────────┘   (per session)  └─────┘
```

All frames are single JSON objects. Client→server frames carry an optional `id`
which the bridge echoes on the matching `result` frame. Server→client frames
that are not responses are *events*.

## Transport & auth

- `GET /health` → `{ ok, name, version, ompVersion }` — unauthenticated.
- `POST /pair { code, deviceName }` → `{ token, machine, pushKey }` — exchanges a
  short-lived pairing code (printed by `attache-bridge serve`) for a long-lived
  bearer token. Codes are single-use and expire after 5 minutes. `attache-bridge
  pair` prints guidance pointing at the serve log when you need a fresh one.
  The response also carries a per-device `pushKey`: a fresh base64 32-byte
  AES-256 key the app stores in its shared keychain and later uses to decrypt
  APNs pushes (see docs/notifications.md).
- `GET /ws` — WebSocket upgrade. Authenticate with `Authorization: Bearer <token>`
  or `?token=<token>` (for clients that cannot set headers).
- `POST /verdict { token, approvalId, verdict }` — REST fallback used by the iOS
  notification actions (Allow/Deny from the lock screen), where the app may not
  have time to establish a WebSocket. Same semantics as the `approval_verdict`
  WS command.

Transport security: on a tailnet, WireGuard already encrypts the link, so plain
`ws://` is acceptable. The bridge also runs behind `tailscale serve` for `wss://`
if you prefer (see README).

## Client → server commands

Envelope: `{ id?: string, type: string, ...payload }`.

| type | payload | notes |
|---|---|---|
| `hello` | `{ protocolVersion: 1 }` | first frame; result carries `protocolVersion`, `machine`, `roles`, `approvalMode`, `enabledModels`. The bridge validates `protocolVersion`: an unsupported major gets a result error with code `protocol_mismatch` and the socket is closed (the app shows an "update required" state) |
| `list_sessions` | `{}` | result: `{ projects: ProjectGroup[] }` — custom projects first (even when empty), then auto-groups by session directory |
| `search_sessions` | `{ query, scope?: "all" \| cwd }` | full-text over titles, ids and message text |
| `list_devices` | `{}` | result: `{ devices: [{ deviceId, name, createdAt, lastSeen? }] }` — the devices paired to this bridge |
| `revoke_device` | `{ deviceId }` | revokes the device's token immediately; any live sockets for that device close with a result error carrying code `revoked` |
| `attach` | `{ sessionId? , sessionPath?, cwd? }` | attach to a live session, resume a stored one, or start fresh in `cwd`. Result: `{ sessionId }`, followed by `session_state` + `history` events |
| `detach` | `{ sessionId }` | stop receiving events (omp process stays alive) |
| `kill_session` | `{ sessionId }` | dispose the omp process |
| `new_session` | `{ cwd?, parentSession? }` | spawn a fresh session, optionally resumed from a stored session file (`parentSession` is an omp session jsonl path). Result: `{ sessionId }` |
| `prompt` | `{ sessionId, message, mode?: "chat"\|"plan"\|"goal"\|"loop", streamingBehavior?: "steer"\|"followUp", images?: [{data, mimeType}] }` | `mode` maps to omp slash-commands; `images` are base64 payloads forwarded to omp's `ImageContent` |
| `steer` | `{ sessionId, message }` | interrupt-path queued message |
| `follow_up` | `{ sessionId, message }` | post-turn queued message |
| `abort` | `{ sessionId }` | stop the current turn |
| `handoff` | `{ sessionId, instructions? }` | omp `handoff` passthrough; `instructions`, when present, is sent as `customInstructions`. The result data comes back verbatim from omp |
| `approval_verdict` | `{ sessionId, approvalId, verdict: "allow"\|"allow_always"\|"deny", scope? }` | `allow_always` also records a bridge-side rule (see below). The optional `scope` (`{ kind: "cwd", cwd }` or `{ kind: "session", sessionId }`) restricts the rule's applicability; absent or malformed scopes fall back to global |
| `get_messages` | `{ sessionId, cursor?, limit? }` | paged history; the bridge drains every page of omp `get_messages_page` and returns the complete result |
| `get_subagents` | `{ sessionId }` | registry snapshot |
| `get_subagent_messages` | `{ sessionId, subagentId, fromByte? }` | incremental transcript reads |
| `steer_subagent` | `{ sessionId, subagentId, message }` | delivered as a directed steer through the primary agent (omp has no direct subagent-steer RPC; the bridge formats it so the primary routes it) |
| `set_model` | `{ sessionId, provider, modelId }` | |
| `set_thinking_level` | `{ sessionId, level }` | `off…max` |
| `set_session_name` | `{ sessionId, name }` | rename the session; result: `{ name }` |
| `set_fast_mode` | `{ sessionId, enabled }` | result: `{ enabled, active }` — toggle fast mode for the session |
| `get_session_stats` | `{ sessionId }` | omp session-stats passthrough (cost, usage) |
| `get_cost_summary` | `{ days? }` | cost/token aggregation over the on-disk session index. Result: `{ days: [{ date, costUSD, tokensIn, tokensOut, sessions }], byProject: [{ projectId, cwd, costUSD, sessions }] }` — `days` defaults to 30 and clamps to [1, 365]; `projectId` is the custom project id for claimed cwds, null otherwise |
| `set_queue_modes` | `{ sessionId, steeringMode?: "all"\|"one-at-a-time", followUpMode?: "all"\|"one-at-a-time", interruptMode?: "immediate"\|"wait" }` | sets per-session queue/interrupt modes via omp's `set_*_mode` RPCs; only provided modes are sent. Result echoes the final computed modes `{ steeringMode, followUpMode, interruptMode }` |
| `branch` | `{ sessionId, entryId }` | fork history at an entry; original untouched |
| `compact` | `{ sessionId }` | |
| `export_html` | `{ sessionId }` | omp exports the transcript to HTML, returned base64 as `{ html }`. Exports over 20MB fail with result code `too_large` (the app can offer the raw file instead) |
| `wake` | `{ mac, address? }` | send a Wake-on-LAN magic packet; `address` defaults to broadcast |
| `get_roles` | `{}` | reads `modelRoles` (+ thinking suffixes) from omp config |
| `get_omp_summary` | `{}` | real environment values for the settings screen (MCP servers, skills, extensions, compaction, fallback chains) |
| `set_role` | `{ role, model?, thinkingLevel? }` | rewrites `modelRoles.<role>` in `~/.omp/agent/config.yml` (applies to new sessions) |
| `set_approval_mode` | `{ sessionId?, mode: "always-ask"\|"write"\|"yolo" }` | with `sessionId`, stores a per-session override in the LiveSession that steers the bridge's auto-approval logic; without `sessionId`, writes the global config used for new sessions |
| `list_rules` / `delete_rule` | | manage bridge-side always-allow rules. `list_rules` returns each rule with its `scope`; rules written before scoping report `{ kind: "global" }` |
| `create_project` | `{ name, cwds? }` | user-defined session grouping (stored in `~/.attache/projects.json`) |
| `rename_project` | `{ projectId, name }` | |
| `delete_project` | `{ projectId }` | sessions fall back to auto-grouping by cwd |
| `assign_cwd` | `{ cwd, projectId \| null }` | claim a session directory for a project (null unassigns) |
| `register_push` | `{ transport: "webhook"\|"apns", target }` | where to deliver offline notifications; empty target unregisters. The `apns` transport delivers an AES-256-GCM ciphertext of each payload to the configured relay (see docs/notifications.md) |
| `test_push` | `{}` | sends a test payload to this device's registered target |
| `get_entries` | `{ sessionId?, sessionPath? }` | branchable entry ids read from the session jsonl (`{ entries: [{id, role, preview, timestamp}] }`). Live sessions read from the session snapshot; pass `sessionPath`, or a `stored:<path>` id as `sessionId`, to read a stored session directly so the app can branch without live observation |
| `ui_response` | `{ sessionId, requestId, value? \| confirmed? \| cancelled? }` | answer a forwarded extension dialog (omp `ask`, select/confirm/input) |
| `upload_file` | `{ sessionId, name, data }` | base64 file written to `<cwd>/attache-uploads/` (25MB cap); result `{ path }` — reference it in the next prompt |

`get_messages` failure handling: a `session_busy` error is retried with
backoff for up to ~10 seconds, then returned as-is with code `session_busy`. A
`stale_cursor` error restarts the drain once; a second failure propagates to
the app.

## Server → client events

| type | payload | notes |
|---|---|---|
| `result` | `{ id, ok, data?, error?, code? }` | response to any command; `code` carries a machine-readable error code when the failure is expected (`protocol_mismatch`, `revoked`, `session_busy`, `stale_cursor`, `too_large`) |
| `machine_info` | `{ name, ompVersion, bridgeVersion, host, uptime }` | on hello and on change |
| `session_state` | `{ sessionId, ...state }` | snapshot: model, thinkingLevel, isStreaming, contextUsage, cost, turn, todoPhases, sessionName, cwd, approvalMode (the real per-session value, overrides applied), fastModeEnabled, fastModeActive, steeringMode, followUpMode, interruptMode |
| `stream` | `{ sessionId, event }` | normalized omp `AgentSessionEvent` (see below) |
| `approval_request` | `{ sessionId, approval }` | `approval: { id, sessionId, tool, prompt, command?, reason?, risk, createdAt, options }`. `prompt` is the full text from omp ("Allow tool: bash\\n…"); `command` and `reason` are parsed out when present |
| `approval_resolved` | `{ sessionId, approvalId, verdict, by }` | `by: "app" \| "tui" \| "rule" \| "timeout" \| "mode"` — resolutions from other surfaces sync here (`mode` = auto-approved by a per-session `yolo` approval-mode override) |
| `subagent` | `{ sessionId, kind: "lifecycle"\|"progress"\|"event", ... }` | forwarded omp subagent frames |
| `advisor` | `{ sessionId, advisor, severity, text, deliveredAs }` | advisor notes, extracted from `<advisory>` injections and `__advisor*.jsonl` |
| `sessions_changed` | `{}` | hint to re-run `list_sessions` |
| `commands` | `{ sessionId, commands }` | forwarded from omp's `available_commands_update`; apps may ignore for now |
| `bye` | `{ reason }` | graceful bridge shutdown; emitted to every connected socket. The app treats it as a clean disconnect, no reconnect/backoff loop |

### Normalized stream events

`stream.event` keeps omp's shapes (`message_start/update/end`,
`tool_execution_start/update/end`, `agent_start/end`, `turn_start/end`,
`auto_compaction_*`, `model_changed`, …) with two additions:

- text deltas are coalesced server-side to ≤ 30 frames/sec per session;
- every frame carries `seq` (monotonic per session) so the app can detect gaps
  after a reconnect and re-fetch via `get_messages`.

### Approvals

omp surfaces approval prompts as `extension_ui_request { method: "select",
options: ["Approve", "Deny"] }` with a text prompt (`Allow tool: bash\n…`), plus
`tool_approval_requested` / `tool_approval_resolved` extension events. The
bridge parses these into structured `approval_request` events (tool, command,
reason, risk tier) and answers omp when a verdict arrives from any surface.

`allow_always` is a **bridge** feature: omp has no per-pattern "always allow"
RPC, so the bridge stores a rule (`~/.attache/rules.json`, keyed by tool +
normalized command prefix) and auto-approves future matching requests, emitting
`approval_resolved { by: "rule" }` so the app can render the "rule added" line.
Rules are visible and revocable (`list_rules` / `delete_rule`).

An `allow_always` verdict may carry a `scope` restricting which sessions the
recorded rule applies to: `{ kind: "cwd", cwd }` or `{ kind: "session",
sessionId }`. Absent or malformed scopes resolve to global — the legacy
behavior, and how rules written before scoping are read. `list_rules` reports
each rule's scope. When several rules match a request, the most specific wins
(session over cwd over global), so a narrower rule is never shadowed by a
broader one.

Pending approvals expire. The bridge enforces an approval timeout
(`approvalTimeoutSec`, default 300, `0` disables). On expiry it answers omp
with Deny, emits `approval_resolved { by: "timeout" }`, and clears the pending
request. The app should render a timed-out approval like a denial.

### Advisor

Advisor notes reach the primary transcript as `<advisory advisor="…"
severity="…">` blocks inside injected messages. The bridge detects them, strips
the wrapper, and emits first-class `advisor` events so the app can render the
distinct advisor voice block. "Ask agent to address" in the app is an ordinary
`steer` whose text quotes the note.

## Versioning

`hello` negotiates `protocolVersion`. Breaking changes bump the major version;
the bridge keeps one prior major alive. A client speaking an unsupported major
gets a result error with code `protocol_mismatch` and its socket is closed, so
the app can show an "update required" state. The Swift and TypeScript models
are both generated from the tables above — keep this file authoritative.
