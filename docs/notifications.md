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
- Resolving an approval anywhere (TUI, app, rule) clears the delivered
  notification.
- Turn-done and advisor notes emit plain notifications.

Limitation: once iOS fully suspends the app, the socket is gone and nothing
arrives until next launch.

## Tier 2 — implemented: bridge webhooks (self-hosted push)

When **no client is connected**, the bridge pushes each notification-worthy
event to any registered webhook (`register_push { transport: "webhook",
target }`). This is designed for [ntfy](https://ntfy.sh) — self-hostable, has
its own iOS app with instant delivery — or anything on your tailnet. Headers
(`title`, `priority`, `tags`) are pre-set so an ntfy topic renders nicely with
zero config. Off by default; the bridge never contacts a third party unless
you point it at one.

## Tier 3 — designed: APNs relay for the App Store build

For real lock-screen Allow/Deny while the app is suspended, APNs is
unavoidable. The privacy-preserving pattern (as used by Home Assistant's
mobile apps):

1. The app registers for remote notifications and hands its device token to
   the bridge (`register_push { transport: "apns", target: <token> }`).
2. The bridge encrypts the payload with a key exchanged at pairing time
   (the relay must not be able to read approval contents).
3. The bridge POSTs `{ deviceToken, ciphertext }` to a **stateless relay**
   (a ~50-line Cloudflare Worker holding the APNs signing key for the App
   Store bundle id). The relay forwards to APNs and stores nothing.
4. A Notification Service Extension in the app decrypts and renders the
   category with Allow/Deny actions; the verdict travels back over `/verdict`
   directly to the bridge — never through the relay.

Self-builders can run their own relay with their own APNs key, or skip Tier 3
entirely and use Tier 2. The `Push` module in `bridge/src/push.ts` is the seam
where the relay client lands.

## Live Activities

The Live Activity / Dynamic Island designs (session card with current tool,
context bar, `ctx · $ · agents`; compact `å + dot + T14`) update locally while
the app runs via ActivityKit, and via APNs `liveactivity` pushes (Tier 3
plumbing) once the relay exists.
