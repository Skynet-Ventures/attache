#!/usr/bin/env bun
/**
 * attache-bridge CLI.
 *
 *   attache-bridge serve [--port 8674] [--host 0.0.0.0] [--omp <path>]
 *   attache-bridge pair           # print the pairing code a running bridge issued (or serve guidance)
 *   attache-bridge devices        # list paired devices
 *   attache-bridge revoke <id>    # revoke a device token immediately
 */

import { networkInterfaces } from "node:os";
import { BridgeServer } from "./server";
import { Auth } from "./auth";

const DEFAULT_PORT = 8674; // "OMP4"

function flag(name: string, fallback?: string): string | undefined {
	const idx = process.argv.indexOf(`--${name}`);
	if (idx >= 0 && process.argv[idx + 1]) return process.argv[idx + 1];
	return fallback;
}

function tailnetAddresses(): string[] {
	const out: string[] = [];
	for (const [, addrs] of Object.entries(networkInterfaces())) {
		for (const addr of addrs ?? []) {
			if (addr.family === "IPv4" && !addr.internal) out.push(addr.address);
		}
	}
	// Tailscale CGNAT range first — that's the address the phone should use.
	return out.sort((a, b) => Number(b.startsWith("100.")) - Number(a.startsWith("100.")));
}

function printPairingBlock(code: string, port: number): void {
	const addrs = tailnetAddresses();
	const primary = addrs[0] ?? "<this-machine>";
	console.log("");
	console.log("  Pair your phone — in Attaché enter:");
	console.log("");
	console.log(`    address   ${primary}:${port}`);
	console.log(`    code      ${code.slice(0, 2)} ${code.slice(2, 4)} ${code.slice(4, 6)} ${code.slice(6, 8)}`);
	console.log("");
	if (addrs.length > 1) console.log(`  (other addresses: ${addrs.slice(1).join(", ")})`);
	console.log("  The code is single-use and expires in 5 minutes.");
	console.log("");
}

const command = process.argv[2] ?? "serve";

if (command === "serve") {
	const port = Number(flag("port", String(DEFAULT_PORT)));
	const host = flag("host", "0.0.0.0")!;
	const server = new BridgeServer({ port, host, ompBin: flag("omp") });
	const { url, code } = await server.start();
	console.log(`attache-bridge listening on ${url}`);
	printPairingBlock(code, port);

	// Graceful shutdown: announce `bye` to every client before closing so the
	// app treats this as a clean disconnect instead of a reconnect storm.
	for (const signal of ["SIGINT", "SIGTERM"] as const) {
		process.once(signal, () => {
			console.log(`[bridge] ${signal}, shutting down gracefully`);
			void server.shutdown("bridge shutting down").finally(() => process.exit(0));
		});
	}
} else if (command === "pair") {
	const auth = new Auth();
	await auth.load();
	const code = auth.persistedCode;
	if (code) {
		// A serve process issued (and persisted) this code within the TTL —
		// print it so the user need not dig through the serve log.
		printPairingBlock(code, Number(flag("port", String(DEFAULT_PORT))));
		console.log(`  (code copied from the running bridge's state — single-use, expires in 5 minutes.)`);
	} else {
		console.log("No active pairing code on disk.");
		console.log("Run `attache-bridge serve` — it prints a fresh pairing code on startup,");
		console.log("or restart a running bridge to re-issue one. Codes are single-use.");
	}
} else if (command === "devices") {
	const auth = new Auth();
	await auth.load();
	const devices = auth.listDevices();
	if (devices.length === 0) console.log("No paired devices.");
	for (const d of devices) {
		console.log(`${d.id}  ${d.name}  paired ${d.createdAt}  last seen ${d.lastSeenAt}`);
	}
} else if (command === "revoke") {
	const deviceId = process.argv[3];
	if (!deviceId) {
		console.log("usage: attache-bridge revoke <deviceId>");
		process.exit(1);
	}
	const auth = new Auth();
	await auth.load();
	const revoked = await auth.revoke(deviceId);
	if (revoked) {
		console.log(`Revoked device ${deviceId}. Its live sessions close with result code \`revoked\`.`);
	} else {
		console.log(`No paired device with id ${deviceId}.`);
		process.exit(1);
	}
} else {
	console.log("usage: attache-bridge [serve|pair|devices|revoke <id>] [--port N] [--host H] [--omp PATH]");
	process.exit(1);
}
