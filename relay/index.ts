/**
 * Stateless APNs relay for Attaché (Tier 3 notifications).
 *
 * The bridge POSTs `{ deviceToken, ciphertext }`. This worker validates the
 * shared bearer, signs an APNs JWT (ES256) from the App Store signing key, and
 * forwards the ciphertext to APNs inside a mutable-notification envelope. It
 * stores nothing. The Notification Service Extension in the app decrypts the
 * ciphertext with the key exchanged at pairing time — the relay never sees
 * approval contents.
 *
 * Secrets (via `wrangler secret put`): RELAY_BEARER, APNS_KEY, APNS_KEY_ID,
 * APNS_TEAM_ID. Vars (wrangler.toml): APNS_TOPIC, APNS_ENDPOINT.
 */

export interface Env {
	RELAY_BEARER?: string;
	/** Apple Push Notifications Service signing key, PKCS#8 PEM (the .p8 file contents). */
	APNS_KEY: string;
	APNS_KEY_ID: string;
	APNS_TEAM_ID: string;
	/** The app's bundle identifier (the `apns-topic` for the App Store build). */
	APNS_TOPIC: string;
	APNS_ENDPOINT?: string;
}

interface RelayRequest {
	deviceToken?: unknown;
	ciphertext?: unknown;
}

const TOKEN_TTL_SEC = 3600;
const TOKEN_RENEW_MARGIN_SEC = 600;

// The Cloudflare `ExportedHandler` type lives in @cloudflare/workers-types;
// this module intentionally has zero dependencies and exports the `{ fetch }`
// shape wrangler expects at runtime.
export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		if (request.method !== "POST") {
			return new Response("method not allowed", { status: 405 });
		}
		if (!authorized(request, env.RELAY_BEARER)) {
			return new Response("unauthorized", { status: 401 });
		}
		let body: RelayRequest;
		try {
			body = (await request.json()) as RelayRequest;
		} catch {
			return new Response("invalid json", { status: 400 });
		}
		const { deviceToken, ciphertext } = body;
		if (typeof deviceToken !== "string" || deviceToken.length === 0) {
			return new Response("missing deviceToken", { status: 400 });
		}
		if (typeof ciphertext !== "string" || ciphertext.length === 0) {
			return new Response("missing ciphertext", { status: 400 });
		}

		const token = await apnsToken(env);
		const endpoint = env.APNS_ENDPOINT || "api.push.apple.com";
		const res = await fetch(`https://${endpoint}/3/device/${encodeURIComponent(deviceToken)}`, {
			method: "POST",
			headers: {
				authorization: `bearer ${token}`,
				"apns-topic": env.APNS_TOPIC,
				"apns-push-type": "alert",
				"content-type": "application/json",
			},
			// Mutable envelope so the app's notification service extension can
			// decrypt `ciphertext` and render the final alert/category (the
			// relay cannot — it would otherwise see the approval contents).
			body: JSON.stringify({
				aps: { "mutable-content": 1, "content-available": 1 },
				ciphertext,
			}),
		});
		const apnsBody = await res.text();
		return new Response(JSON.stringify({ ok: res.ok, status: res.status, apns: apnsBody }), {
			status: res.ok ? 200 : 502,
			headers: { "content-type": "application/json" },
		});
	},
};

function authorized(request: Request, expected: string | undefined): boolean {
	if (!expected) return true; // no bearer configured → open (self-hosted convenience)
	const header = request.headers.get("authorization") ?? "";
	const presented = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
	if (presented.length !== expected.length) return false;
	let diff = 0;
	for (let i = 0; i < presented.length; i++) diff |= presented.charCodeAt(i) ^ expected.charCodeAt(i);
	return diff === 0;
}

// --- APNs provider token (ES256 JWT) ---------------------------------------

let cachedToken: { jwt: string; expiresAt: number } | null = null;

/**
 * Signs an APNs provider token with WebCrypto (ES256). WebCrypto produces a
 * raw r||s signature; JWT/ES256 requires DER-encoded ECDSA, which we encode
 * here.
 */
async function apnsToken(env: Env): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	if (cachedToken && cachedToken.expiresAt - TOKEN_RENEW_MARGIN_SEC > now) return cachedToken.jwt;
	const jwt = await signProviderToken(env, now);
	cachedToken = { jwt, expiresAt: now + TOKEN_TTL_SEC };
	return jwt;
}

async function signProviderToken(env: Env, iat: number): Promise<string> {
	const header = { alg: "ES256", kid: env.APNS_KEY_ID };
	const claims = { iss: env.APNS_TEAM_ID, iat };
	const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
	const key = await crypto.subtle.importKey(
		"pkcs8",
		pemToBytes(env.APNS_KEY),
		{ name: "ECDSA", namedCurve: "P-256" },
		false,
		["sign"],
	);
	const signature = new Uint8Array(
		await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput)),
	);
	return `${signingInput}.${b64url(derEncodeEcdsa(signature))}`;
}

/**
 * JWT ES256 requires the ECDSA signature in DER form (SEQUENCE of two
 * INTEGERs). WebCrypto implementations disagree on output format: most return
 * a raw 64-byte r||s pair, while some return DER already (a DER value always
 * starts with 0x30). Detect and normalize so the token verifies against APNs.
 */
function derEncodeEcdsa(signature: Uint8Array): Uint8Array {
	if (signature[0] === 0x30) return signature; // already DER
	if (signature.byteLength !== 64) throw new Error("unexpected ES256 signature length");
	const r = derInteger(signature.subarray(0, 32));
	const s = derInteger(signature.subarray(32));
	const body = new Uint8Array([...r, ...s]);
	const length = body.length < 128 ? [body.length] : [0x81, body.length];
	return new Uint8Array([0x30, ...length, ...body]);
}

/**
 * ASN.1 INTEGER bytes for a fixed-length big-endian octet string: strip
 * leading zeros; prepend 0x00 when the high bit is set to keep it positive.
 */
function derInteger(octets: Uint8Array): Uint8Array {
	let start = 0;
	while (start < octets.length - 1 && octets[start] === 0) start++;
	const trimmed = octets.subarray(start);
	const pad = trimmed[0] & 0x80 ? [0x00] : [];
	return new Uint8Array([0x02, trimmed.length + pad.length, ...pad, ...trimmed]);
}

function b64url(input: string | Uint8Array): string {
	const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
	let bin = "";
	for (const b of bytes) bin += String.fromCharCode(b);
	return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBytes(pem: string): Uint8Array<ArrayBuffer> {
	const b64 = pem.replace(/-----BEGIN [^-]+-----/g, "").replace(/-----END [^-]+-----/g, "").replace(/\s+/g, "");
	const bin = atob(b64);
	const bytes = new Uint8Array(new ArrayBuffer(bin.length));
	for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	return bytes;
}
