/**
 * Wake-on-LAN: send a magic packet (6×0xFF + 16×MAC) via UDP broadcast.
 */

export function parseMac(mac: string): Uint8Array | null {
	const parts = mac.trim().split(/[:\-]/);
	if (parts.length !== 6) return null;
	const bytes = new Uint8Array(6);
	for (let i = 0; i < 6; i++) {
		const value = Number.parseInt(parts[i]!, 16);
		if (Number.isNaN(value) || value < 0 || value > 255) return null;
		bytes[i] = value;
	}
	return bytes;
}

export async function sendMagicPacket(mac: string, address = "255.255.255.255", port = 9): Promise<void> {
	const macBytes = parseMac(mac);
	if (!macBytes) throw new Error(`invalid MAC address: ${mac}`);
	const packet = new Uint8Array(6 + 16 * 6);
	packet.fill(0xff, 0, 6);
	for (let i = 0; i < 16; i++) packet.set(macBytes, 6 + i * 6);

	const socket = await Bun.udpSocket({});
	try {
		socket.setBroadcast(true);
		socket.send(packet, port, address);
		// Fire twice: WOL packets are cheap and lossy networks eat them.
		await new Promise(resolve => setTimeout(resolve, 50));
		socket.send(packet, port, address);
	} finally {
		socket.close();
	}
}
