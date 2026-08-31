/**
 * Relay smoke harness — run with `bun smoke.mjs`.
 *
 * Exercises the worker end-to-end against a stubbed APNs endpoint and proves
 * the ES256 JWT signature is valid DER ECDSA (the format APNs requires).
 * Node's `crypto.verify(..., { dsaEncoding: "der" })` is the verifier — Bun's
 * WebCrypto `verify` only accepts the raw r||s form, so it would falsely
 * reject the (correct) DER-encoded token.
 *
 * No network, no secrets, no deps: the P-256 keypair is generated in memory.
 */

import { generateKeyPairSync, verify } from "node:crypto";
import WorkerModule from "./index.ts";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });

const env = {
	RELAY_BEARER: "sekrit",
	APNS_KEY: privateKey.export({ type: "pkcs8", format: "pem" }),
	APNS_KEY_ID: "ABC1234567",
	APNS_TEAM_ID: "TEAM000001",
	APNS_TOPIC: "io.skynetventures.attache",
	APNS_ENDPOINT: "fake.push.apple.com",
};

let apnsRequest = null;
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
	if (String(url).includes("fake.push.apple.com")) {
		apnsRequest = { url: String(url), init };
		return new Response("{}", { status: 200 });
	}
	return realFetch(url, init);
};

const post = (headers, body) =>
	WorkerModule.fetch(new Request("http://relay/", { method: "POST", headers, body }), env);

try {
	// Bearer enforcement.
	if ((await post({}, "{}")).status !== 401) throw new Error("missing bearer not rejected");
	if ((await post({ authorization: "Bearer wrong" }, "{}")).status !== 401) throw new Error("wrong bearer not rejected");
	if ((await post({ authorization: "Bearer sekrit" }, JSON.stringify({ deviceToken: "", ciphertext: "x" }))).status !== 400) {
		throw new Error("empty deviceToken not rejected");
	}

	// Happy path.
	const res = await post({ authorization: "Bearer sekrit" }, JSON.stringify({ deviceToken: "deadbeef", ciphertext: "QUJD" }));
	if (res.status !== 200) throw new Error(`happy path failed: ${res.status}`);
	if (!apnsRequest || apnsRequest.url !== "https://fake.push.apple.com/3/device/deadbeef") {
		throw new Error("worker did not forward to the APNs endpoint");
	}
	const auth = apnsRequest.init.headers.authorization;
	if (!auth || !auth.startsWith("bearer ")) throw new Error("missing bearer token for APNs");
	const [h, payload, sig] = auth.slice("bearer ".length).split(".");
	const header = JSON.parse(Buffer.from(h, "base64url").toString());
	const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
	if (header.alg !== "ES256" || header.kid !== env.APNS_KEY_ID) throw new Error("JWT header wrong");
	if (claims.iss !== env.APNS_TEAM_ID || typeof claims.iat !== "number") throw new Error("JWT claims wrong");

	const valid = verify(
		"sha256",
		Buffer.from(`${h}.${payload}`),
		{ key: publicKey.export({ type: "spki", format: "pem" }), dsaEncoding: "der" },
		Buffer.from(sig, "base64url"),
	);
	if (!valid) throw new Error("JWT ES256 signature is not valid DER ECDSA");

	if (apnsRequest.init.headers["apns-topic"] !== env.APNS_TOPIC) throw new Error("wrong apns-topic");
	const envelope = JSON.parse(apnsRequest.init.body);
	if (envelope.ciphertext !== "QUJD" || envelope.aps["mutable-content"] !== 1) throw new Error("envelope wrong");

	console.log("relay smoke OK: bearer auth, APNs forwarding, envelope, and JWT signature all valid");
} finally {
	globalThis.fetch = realFetch;
}
