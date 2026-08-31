# Notifications

The design brief: approvals, goal completions, and advisor interrupts land on
the lock screen with **Allow / Deny** right there — without compromising the
"nothing leaves your machines" promise. That tension (APNs requires a server)
is resolved in three tiers.

## Tier 1 — implemented: local notifications + REST verdicts

While the app has a live WebSocket (foreground, or the short background window
iOS grants), `NotificationManager` mirrors bridge events to local
notifications:

- **Approvals** use a `UNNotificationCategory` with `Allow once` / `Deny`
  actions (both `authenticationRequired`, so Face ID gates them on the lock
  screen) and `timeSensitive` interruption level.
- Verdict actions POST to the bridge's `/verdict` REST endpoint rather than
  requiring the WebSocket — iOS wakes the app just long enough for that call.
- Resolving an approval anywhere (TUI, app, rule, timeout) clears the delivered
  notification.
- Turn-done and advisor notes emit plain notifications; a turn-done
  notification fires only when the turn's `agent_end` event reports
  `isTerminal !== false`, so mid-turn pauses don't page you.

Limitation: once iOS fully suspends the app, the socket is gone and nothing
arrives until next launch.

## Tier 2 — implemented: bridge webhooks (self-hosted push)

When the affected **session has no attached socket**, the bridge pushes each
notification-worthy event to any registered webhook (`register_push {
transport: "webhook", target }`). Gating is per-session: being attached to one
session does not suppress another session's pushes. This is designed for
[ntfy](https://ntfy.sh) — self-hostable, has its own iOS app with instant
delivery — or anything on your tailnet. Headers (`title`, `priority`, `tags`)
are pre-set so an ntfy topic renders nicely with zero config. Off by default;
the bridge never contacts a third party unless you point it at one.

## Tier 3 — implemented: APNs relay for the App Store build

For real lock-screen Allow/Deny while the app is suspended, APNs is
unavoidable. The privacy-preserving pattern (as used by Home Assistant's
mobile apps) is implemented end to end:

1. Pairing exchanges a per-device AES-256 key: the `/pair` response carries
   `pushKey` (base64 32 bytes), which the app stores in the keychain access
   group shared with its notification service extension.
2. The app registers for remote notifications and hands its device token to
   the bridge (`register_push { transport: "apns", target: <token> }`).
3. The bridge encrypts each payload with that key — AES-256-GCM, 12-byte IV
   prepended, 16-byte auth tag appended, all base64 — so the relay can never
   read approval contents. It POSTs `{ deviceToken, ciphertext }` to the
   relay configured via `apnsRelayUrl` / `apnsRelayBearer` in
   `~/.attache/config.json`.
4. The `relay/` Cloudflare Worker holds the APNs signing key for the App
   Store bundle id. It validates the shared bearer, signs an ES256 APNs
   provider token, and forwards the ciphertext inside a mutable-notification
   envelope (`aps.mutable-content: 1`); it stores nothing.
5. The Notification Service Extension (`ios/AttacheNotificationService`)
   decrypts with the same key and re-renders. Approvals reuse the app's
   APPROVAL category with Allow/Deny actions (approvalId, sessionId and host
   ride in userInfo so the app can answer); the verdict travels back over
   `/verdict` directly to the bridge — never through the relay. On any
   decryption failure the original APNs content is presented unchanged.

Self-builders can run their own relay with their own APNs key (deploy and
config in `relay/README.md`), or skip Tier 3 entirely and use Tier 2.

## Live Activities

The Live Activity / Dynamic Island designs (session card with current tool,
context bar, `ctx · $ · agents`; compact `å + dot + T14`) update locally while
the app runs via ActivityKit. The app also registers its live-activity
push-to-start token with every paired bridge
(`register_push { transport: "liveactivity", target: <token> }`) — a
registration-only seam for now: the bridge persists the target but does not
send liveactivity pushes this wave, so suspended-app updates still wait on
that path.
