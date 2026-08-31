# APNs relay

A stateless Cloudflare Worker that delivers Attaché's offline notifications to
Apple Push Notification service (APNs) **without ever seeing their contents**.

The bridge encrypts each payload with a per-device key exchanged at pairing
time (AES-256-GCM) and POSTs `{ deviceToken, ciphertext }` here. This worker
validates a shared bearer, signs an APNs provider token with the App Store
signing key, and forwards the ciphertext inside a mutable-notification
envelope (`aps.mutable-content: 1`). The app's Notification Service Extension
decrypts it and renders the Allow/Deny actions. The worker stores nothing and
holds no user data — its only secrets are the APNs signing key and the bearer.

## Architecture

```
bridge ──POST { deviceToken, ciphertext }──▶ worker ──HTTP/2──▶ APNs ──▶ device
            (AES-256-GCM, per-device key)         │ stores nothing
                                                  └─ never sees plaintext
```

## Deploy

1. Have an Apple Push Notification service **APNs Auth Key** (.p8) and its
   **Key ID** and **Team ID**, all from the same Apple Developer team that
   signs the Attaché App Store build.

2. Install wrangler and log in:

   ```sh
   npm i -g wrangler
   wrangler login
   ```

3. Set the secrets (never commit them):

   ```sh
   wrangler secret put RELAY_BEARER        # shared bearer the bridge sends
   wrangler secret put APNS_KEY            # the .p8 file CONTENTS (PEM)
   wrangler secret put APNS_KEY_ID         # 10-char key id from the portal
   wrangler secret put APNS_TEAM_ID        # Apple Developer team id
   ```

4. If your bundle id differs from `wrangler.toml`'s `APNS_TOPIC`, override it
   (a non-secret var). Use `APNS_ENDPOINT = "api.sandbox.push.apple.com"` while
   testing against a development profile.

5. Deploy:

   ```sh
   wrangler deploy
   ```

6. Point the bridge at the deployed URL (and the bearer) in
   `~/.attache/config.json`:

   ```json
   {
     "approvalTimeoutSec": 300,
     "apnsRelayUrl": "https://attache-apns-relay.<your-subdomain>.workers.dev",
     "apnsRelayBearer": "<the RELAY_BEARER you set>"
   }
   ```

   The bearer is optional: if `RELAY_BEARER` is unset the worker is open
   (fine for a private personal relay).

## Behavior

- `POST /` with JSON `{ deviceToken, ciphertext }` → forwards to APNs.
- Verifies `Authorization: Bearer <RELAY_BEARER>` (constant-time compare) when
  the secret is configured; `401` otherwise.
- Signs a fresh APNs provider token per hour (ES256 JWT; cached with a renewal
  margin) using the env signing key.
- Responds `200` with `{ ok: true, status, apns }` on APNs success, `502` with
  the APNs body when APNs rejects.
- No state, no writes, no analytics.

## Local verification

`bun smoke.mjs` generates an in-memory P-256 keypair, drives the worker
against a stubbed APNs endpoint, and proves the ES256 JWT signature is valid
DER ECDSA (using Node's `crypto.verify`, since WebCrypto only accepts the raw
signature form). Requires a working APNs key only to sign for real — the smoke
needs nothing but Bun.

