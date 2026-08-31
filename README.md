# Attaché

**A native iOS remote for [omp](https://omp.sh). Full visibility, zero terminal.**

Attaché drives omp coding-agent sessions from your phone: watch live turn
streams, answer tool approvals (in the stream, in a queue, or straight from the
lock screen), review plans and diffs, watch the advisor flag the working agent,
steer subagents mid-flight, and manage model roles — over your own Tailscale
network, with nothing relayed through anyone's cloud.

<p>
<em>Dark-only "Signal" design · SwiftUI · iOS 17+</em>
</p>

## How it works

omp speaks a newline-delimited JSON RPC over stdio (`omp --mode rpc`) — it has
no network server. Attaché therefore ships in two parts:

```
┌─────────────┐   WebSocket (docs/protocol.md)  ┌────────────────┐  NDJSON stdio  ┌─────┐
│ Attaché iOS │ ◄═════════════════════════════► │ attache-bridge │ ◄════════════► │ omp │
└─────────────┘        your tailnet             └────────────────┘  per session   └─────┘
```

- **`bridge/`** — `attache-bridge`, a small [Bun](https://bun.sh) daemon you run
  on the machine that runs omp. It spawns/attaches `omp --mode rpc` processes,
  scans omp's session store for the resume picker, intercepts approval prompts,
  keeps "always allow" rules, and exposes everything over an authenticated
  WebSocket.
- **`ios/`** — the SwiftUI app. Demo mode works with no machine at all
  ("Explore with demo data" on first launch).

## Quick start

On the machine running omp (needs [Bun](https://bun.sh) ≥ 1.1):

```bash
cd bridge
bun install
bun run start          # prints the address + one-time pairing code
```

On your phone: build & run `ios/Attache.xcodeproj` (see below), tap
**Pair your first machine**, and enter the address and code the bridge printed.
On a tailnet, use the machine's `100.x.y.z` address — the bridge lists it first.

### Building the app

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ios
xcodegen generate
open Attache.xcodeproj
```

Change `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` before archiving under
your own team.

## What works today

| Area | Status |
|---|---|
| Pairing (code → bearer token in Keychain) | ✅ |
| Home: machine status, pinned running/plan cards, per-project session lists | ✅ |
| Resume picker with deep full-text search across stored sessions | ✅ |
| Live turn stream: text deltas, tool cards, user/steer lines, typing indicator | ✅ |
| Composer: CHAT/PLAN/GOAL/LOOP modes, @role picker, slash palette, stop turn | ✅ |
| Approvals: inline card, queue screen, Deny / Allow once / Always (bridge rules) | ✅ |
| Lock-screen approval notifications with Allow/Deny actions (app running/background) | ✅ |
| Advisor notes as first-class blocks, "Ask agent to address" → steer | ✅ |
| Subagent hub: live tiles, transcripts, steering (routed via the primary agent) | ✅ |
| Plan review: steps, reject/refine/accept | ✅ |
| Full-screen diff review with request-changes / looks-good | ✅ |
| Roles & settings: thinking-level cycling, approval mode (writes omp config) | ✅ |
| Offline: banner, queued sends, auto-reconnect with backoff | ✅ |
| Demo mode (no machine needed; App Store review friendly) | ✅ |
| Custom projects: group session directories under one name, synced via the bridge | ✅ |
| Live Activity + Dynamic Island (session, status, context bar, approval chip) | ✅ (updates while the app runs) |
| Auto re-attach + transcript backfill after reconnects (seq-gap detection) | ✅ |
| Webhook push (ntfy-ready) configurable in Settings, with send-test | ✅ |
| Extension dialogs (omp `ask`, select/confirm/input) answerable inline | ✅ |
| Always-allow rules review/revoke screen | ✅ |
| @role picker sets model+thinking; separate session model picker | ✅ |
| Photo attachments in the composer (sent as omp image content) | ✅ |
| Branch sheet backed by real session entry ids | ✅ |
| Dispatch a subagent from the agent hub | ✅ (routed via the primary agent) |

Roadmap (see `docs/`): APNs push relay for fully-suspended delivery (also
unlocks push-updated Live Activities), QR pairing, branch-from-turn UI wired
to omp entry ids, wake-on-LAN, multi-machine switching.

## Repository layout

```
bridge/     attache-bridge daemon (Bun + TypeScript)
ios/        SwiftUI app (XcodeGen project)
docs/       protocol spec, architecture, notification design
design/     original design handoff (pixel/behavior reference)
```

## Security model

- Pairing codes are single-use and expire in 5 minutes; the app stores a random
  256-bit bearer token in the iOS Keychain, the bridge stores only its SHA-256.
- The bridge binds to your interfaces but is intended to be reached over
  Tailscale (WireGuard-encrypted). For TLS on top, front it with
  `tailscale serve`.
- "Always allow" rules live on the bridge (`~/.attache/rules.json`), are scoped
  to tool + command prefix, and are listable/revocable.
- The bridge never talks to any third party. Webhook push (e.g. an ntfy topic)
  is opt-in and off by default.

## Development

```bash
cd bridge && bun test && bunx tsc --noEmit     # bridge tests + types
cd ios && xcodegen generate && xcodebuild -scheme Attache \
  -destination 'generic/platform=iOS Simulator' build
```

The bridge ↔ app protocol is specified in [docs/protocol.md](docs/protocol.md);
the design reference lives in [design/](design/HANDOFF.md).

## License

MIT — see [LICENSE](LICENSE).
