# Architecture

## Why a bridge exists

omp's only programmatic surface is `omp --mode rpc`: newline-delimited JSON
over **stdio** (see the [oh-my-pi RPC reference](https://omp.sh/docs/rpc)).
There is no network listener, no auth, no multi-client story. Something on the
Mac has to own the omp processes and speak to the phone; that something is
`attache-bridge`.

The bridge is deliberately thin:

- **Process manager** — one `omp --mode rpc` child per attached session
  (`--cwd` for new sessions, `-r <jsonl path>` for resumes). Children exit when
  the bridge closes their stdin, per omp's protocol contract.
- **Frame codec** — NDJSON parsing plus protocol-v2 `rpc_chunk` reassembly for
  oversized frames (`bridge/src/rpc/frames.ts`).
- **Normalizer** — translates omp's event stream into the app protocol
  (`docs/protocol.md`): coalesced text deltas, structured approvals, advisor
  notes, subagent frames.
- **Session index** — read-only scans of `~/.omp/agent/sessions/<encoded-cwd>/
  *.jsonl` for the home screen and resume picker; deep search streams raw
  jsonl for substring hits.
- **Approvals + rules** — omp emits approval prompts as extension-UI `select`
  requests (`Allow tool: …` / Approve / Deny). The bridge parses them, holds
  them pending, answers when any surface (app, notification, rule, or the
  approval timeout) resolves, and owns "always allow" rules — omp itself has
  no such RPC, so this is a bridge feature by design, keeping rule storage
  inspectable at `~/.attache/rules.json`.
- **Auth** — single-use pairing codes → per-device bearer tokens (hashed at
  rest). See README "Security model".
- **Push gating** — offline push fires per session: the bridge pushes an event
  only when that session has no attached socket, never when the bridge as a
  whole has no clients. A phone attached to session A still hears session B's
  approval as a push.

Anything omp can express, the app should render; anything the app can't render
yet still flows through the `stream` event so nothing is silently dropped.

## iOS app structure

```
App/        AttacheApp (entry, onboarding routing), AppModel (@Observable state)
Theme/      design tokens (colors/typography/metrics) + shared building blocks
Models/     UI models (ChatItem, ApprovalModel, SubagentModel, PlanModel, …)
Services/   Engine implementations + networking + notifications
Views/      one file per screen, matching the design handoff's 11 screens
```

The key seam is the `Engine` protocol (`App/AppModel.swift`): every user intent
(send, steer, verdict, plan actions, thinking-level cycling…) goes through it.

- **DemoEngine** — scripted world matching the design prototype; drives
  onboarding's "Explore with demo data" and App Store review.
- **BridgeEngine** — real implementation over `BridgeClient` (a
  `URLSessionWebSocketTask` wrapper with id-correlated requests and
  exponential-backoff reconnect).

Because views only read `AppModel` and only call `Engine`, screens don't know
which world they're in — the entire UI is exercisable without a machine.

## Design fidelity

`design/` contains the authoritative handoff (direction 1a "Signal"). Colors,
type, spacing, and behavior in `Theme/` and the views are transcribed from it;
when in doubt, the prototype's inline styles win. The app is dark-only by
design (`UIUserInterfaceStyle: Dark`).

## Trade-offs and roadmap notes

- **Subagent steering** — omp has no direct subagent-steer RPC; the bridge
  routes steers through the primary agent with an explicit visible prefix.
- **Branching** — branch points come from the session jsonl via `get_entries`:
  live sessions read the snapshot, stored sessions read the file directly, so
  branching never requires live observation. The branch result itself still
  goes through omp's `branch` RPC, which needs the entry id.
- **iPad split view** — on regular size class the app starts in a
  `NavigationSplitView` (sessions sidebar | stream detail). The detail column
  reuses the iPhone navigation stack, so every flow behaves identically on
  both form factors; only the entry point differs.
- **Home-screen widgets** — the app ships a WidgetKit extension containing a
  home-screen widget and the Live Activity, both fed by snapshots the app
  publishes. They are read-only status surfaces; no widget interaction.
- **Notification Service Extension** — shipped in
  `ios/AttacheNotificationService`. It decrypts APNs pushes with the per-device
  key exchanged at pair time and re-renders them while the app is suspended;
  approvals reuse the app's APPROVAL category. It holds no secrets of its own
  beyond the app-group mirror of the push key and host (see
  docs/notifications.md).
- **Multi-machine support** — the app can hold several paired machines at
  once. Each machine record keeps its own token, push registrations, and
  session routing; the bridge knows nothing about other machines.
- **Approval "risk" tiers** — omp doesn't transmit its internal tier over the
  extension-UI channel, so the bridge infers risk from the tool name, the
  prompt's `Reason:` line, and destructive-command heuristics. Treat it as a
  display hint, not policy.
- **ATS** — the app allows cleartext WebSockets because tailnet addresses
  (100.64.0.0/10) can't be expressed as ATS domain exceptions; the transport
  is WireGuard-encrypted underneath. `tailscale serve` gives wss:// if wanted.
- **Live Activity / Dynamic Island** — updates are local-only while the app
  runs (ActivityKit). The app registers live-activity push-to-start tokens
  with the bridge, but the bridge sends no `liveactivity` pushes yet, so
  updating an activity while suspended remains future. The APNs relay itself
  (Tier 3) is implemented — see docs/notifications.md.
