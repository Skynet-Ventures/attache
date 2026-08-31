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
- `POST /pair { code, deviceName }` → `{ token, machine }` — exchanges a
  short-lived pairing code (printed by `attache-bridge serve` / `attache-bridge pair`)
  for a long-lived bearer token. Codes are single-use and expire after 5 minutes.
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
| `hello` | `{ protocolVersion: 1 }` | first frame; result carries `machine`, `roles`, `limits` |
| `list_sessions` | `{}` | result: `{ projects: ProjectGroup[] }` — custom projects first (even when empty), then auto-groups by session directory |
| `search_sessions` | `{ query, scope?: "all" \| cwd }` | full-text over titles, ids and message text |
| `attach` | `{ sessionId? , sessionPath?, cwd? }` | attach to a live session, resume a stored one, or start fresh in `cwd`. Result: `{ sessionId }`, followed by `session_state` + `history` events |
| `detach` | `{ sessionId }` | stop receiving events (omp process stays alive) |
| `kill_session` | `{ sessionId }` | dispose the omp process |
| `prompt` | `{ sessionId, message, mode?: "chat"\|"plan"\|"goal"\|"loop", role?, streamingBehavior?: "steer"\|"followUp" }` | `mode`/`role` map to omp slash-commands / role models |
| `steer` | `{ sessionId, message }` | interrupt-path queued message |
| `follow_up` | `{ sessionId, message }` | post-turn queued message |
| `abort` | `{ sessionId }` | stop the current turn |
| `approval_verdict` | `{ sessionId, approvalId, verdict: "allow"\|"allow_always"\|"deny" }` | `allow_always` also records a bridge-side rule (see below) |
| `get_messages` | `{ sessionId, cursor?, limit? }` | paged history (drains omp `get_messages_page`) |
| `get_subagents` | `{ sessionId }` | registry snapshot |
| `get_subagent_messages` | `{ sessionId, subagentId, fromByte? }` | incremental transcript reads |
| `steer_subagent` | `{ sessionId, subagentId, message }` | delivered as a directed steer through the primary agent (omp has no direct subagent-steer RPC; the bridge formats it so the primary routes it) |
| `set_model` | `{ sessionId, provider, modelId }` | |
| `set_thinking_level` | `{ sessionId, level }` | `off…max` |
| `branch` | `{ sessionId, entryId }` | fork history at an entry; original untouched |
| `compact` | `{ sessionId }` | |
| `get_roles` | `{}` | reads `modelRoles` (+ thinking suffixes) from omp config |
| `set_role` | `{ role, model?, thinkingLevel? }` | rewrites `modelRoles.<role>` in `~/.omp/agent/config.yml` (applies to new sessions) |
| `set_approval_mode` | `{ sessionId?, mode: "always-ask"\|"write"\|"yolo" }` | per-session override or config default |
| `list_rules` / `delete_rule` | | manage bridge-side always-allow rules |
| `create_project` | `{ name, cwds? }` | user-defined session grouping (stored in `~/.attache/projects.json`) |
| `rename_project` | `{ projectId, name }` | |
| `delete_project` | `{ projectId }` | sessions fall back to auto-grouping by cwd |
| `assign_cwd` | `{ cwd, projectId \| null }` | claim a session directory for a project (null unassigns) |
| `register_push` | `{ transport: "webhook"\|"apns", target }` | where to deliver offline notifications (see docs/notifications.md) |

## Server → client events

| type | payload | notes |
|---|---|---|
| `result` | `{ id, ok, data? , error? }` | response to any command |
| `machine_info` | `{ name, ompVersion, bridgeVersion, host, uptime }` | on hello and on change |
| `session_state` | `{ sessionId, ...state }` | snapshot: model, thinkingLevel, isStreaming, contextUsage, cost, turn, todoPhases, sessionName, cwd, approvalMode |
| `stream` | `{ sessionId, event }` | normalized omp `AgentSessionEvent` (see below) |
| `approval_request` | `{ sessionId, approval }` | `approval: { id, tool, title, command?, diff?, reason?, risk, createdAt, autoResolved? }` |
| `approval_resolved` | `{ sessionId, approvalId, verdict, by }` | `by: "app" \| "tui" \| "rule" \| "timeout"` — resolutions from other surfaces sync here |
| `subagent` | `{ sessionId, kind: "lifecycle"\|"progress"\|"event", ... }` | forwarded omp subagent frames |
| `advisor` | `{ sessionId, advisor, severity, text, deliveredAs }` | advisor notes, extracted from `<advisory>` injections and `__advisor*.jsonl` |
| `sessions_changed` | `{}` | hint to re-run `list_sessions` |
| `bye` | `{ reason }` | server shutdown |

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

### Advisor

Advisor notes reach the primary transcript as `<advisory advisor="…"
severity="…">` blocks inside injected messages. The bridge detects them, strips
the wrapper, and emits first-class `advisor` events so the app can render the
distinct advisor voice block. "Ask agent to address" in the app is an ordinary
`steer` whose text quotes the note.

## Versioning

`hello` negotiates `protocolVersion`. Breaking changes bump the major version;
the bridge keeps one prior major alive. The Swift and TypeScript models are
both generated from the tables above — keep this file authoritative.
