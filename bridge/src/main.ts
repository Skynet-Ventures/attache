#!/usr/bin/env bun
/**
 * attache-bridge CLI.
 *
 *   attache-bridge serve [--port 8674] [--host 0.0.0.0] [--omp <path>]
 *   attache-bridge pair          # print a fresh pairing code for a running setup
 *   attache-bridge devices       # list paired devices
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
} else if (command === "pair") {
	// Pairing codes live in the serve process; this subcommand just reminds
	// the user where to look. (Kept as a distinct command so `--help` output
	// matches the app's copy.)
	console.log("Run `attache-bridge serve` — it prints a pairing code on startup.");
	console.log("A running bridge re-issues a code whenever no valid one is active.");
} else if (command === "devices") {
	const auth = new Auth();
	await auth.load();
	const devices = auth.listDevices();
	if (devices.length === 0) console.log("No paired devices.");
	for (const d of devices) {
		console.log(`${d.id}  ${d.name}  paired ${d.createdAt}  last seen ${d.lastSeenAt}`);
	}
} else {
	console.log("usage: attache-bridge [serve|pair|devices] [--port N] [--host H] [--omp PATH]");
	process.exit(1);
}
