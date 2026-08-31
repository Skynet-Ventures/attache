import Foundation

/// Push context bridging between the app process and the notification service
/// extension (contract H). The NSE cannot read `UserDefaults.standard` from
/// the app's own domain, so the app mirrors the pieces the NSE needs into the
/// shared app group / Keychain (extensions share the app's keychain access
/// group):
///
///  - `push.pushKey` (Keychain): the AES-256-GCM key the bridge encrypts with;
///  - `bridge.host` (app group): bridge address for the /verdict REST call.
///
/// Lives in its own file so pairing/settings changes never touch this seam.
extension AppSettings {
    static let pushKeychainKey = PushSecrets.keychainKey

    /// Mirrors the primary machine's push context. Secondary machines receive
    /// pushes addressed to the same device token, so the lock-screen verdict
    /// targets the machine the payload names — the bridge includes its host
    /// in encrypted messages when available; this mirror is the fallback.
    func refreshPushContextMirror() {
        guard let primary = pairedMachines.first else {
            Keychain.delete(key: Self.pushKeychainKey)
            AttacheAppGroup.defaults?.removeObject(forKey: AttacheAppGroup.hostKey)
            return
        }
        if !primary.pushKey.isEmpty {
            Keychain.write(key: Self.pushKeychainKey, value: primary.pushKey)
        } else {
            Keychain.delete(key: Self.pushKeychainKey)
        }
        AttacheAppGroup.defaults?.set(primary.host, forKey: AttacheAppGroup.hostKey)
    }

    /// Bearer token for a machine reached at `host`, used by the notification
    /// verdict path (no WebSocket involved). Falls back to the legacy single
    /// pairing token, then to the primary machine.
    static func bearerToken(forHost host: String) -> String? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "bridge.machines"),
           let machines = try? JSONDecoder().decode([PairedMachineRecord].self, from: data),
           let match = machines.first(where: { $0.host == host }) {
            return Keychain.read(key: tokenKey(match.id))
        }
        if let token = Keychain.read(key: "bridge.token"), !token.isEmpty {
            return token
        }
        if let data = defaults.data(forKey: "bridge.machines"),
           let machines = try? JSONDecoder().decode([PairedMachineRecord].self, from: data),
           let primary = machines.first {
            return Keychain.read(key: tokenKey(primary.id))
        }
        return nil
    }
}
