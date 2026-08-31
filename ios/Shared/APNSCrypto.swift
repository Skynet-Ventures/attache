import CryptoKit
import Foundation

/// Approval notifications render with Allow-once / Deny actions. The category
/// is registered by the app (NotificationManager) and re-declared by the
/// notification service extension when it re-renders a remote approval — the
/// identifier MUST stay in lockstep, so it lives here, compiled into both.
enum NotificationCategory {
    static let approval = "APPROVAL"
}

/// Key names shared between the app and the notification service extension
/// (contract H). The push key is stored in the Keychain (shared access group);
/// the host fallback rides the app-group mirror.
enum PushSecrets {
    static let keychainKey = "push.pushKey"
}

/// Decrypted remote-push content. The bridge encrypts a JSON document whose
/// shape mirrors its `PushPayload`; unknown fields are tolerated so app and
/// bridge can evolve independently.
struct PushMessageContent: Codable, Equatable {
    var kind: String
    var title: String
    var body: String
    var sessionId: String?
    var approvalId: String?
    var host: String?
}

enum APNSCrypto {
    /// AES-256-GCM decrypt of a `base64(12-byte-iv ‖ ciphertext ‖ tag)` frame
    /// produced by the bridge with the per-device `pushKey` exchanged at pair
    /// time. The first 12 bytes are the GCM nonce; the remainder decrypts to
    /// the UTF-8 JSON payload.
    static func decrypt(payload: String, key: Data) throws -> PushMessageContent {
        let data = try decodeBase64(payload)
        guard data.count > 12 else { throw APNSCryptoError.shortFrame }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        return try JSONDecoder().decode(PushMessageContent.self, from: plain)
    }

    /// Mirror of the bridge encryption: `base64(12-byte-iv ‖ ciphertext ‖ tag)`.
    /// Exercised by the test suite to guarantee the NSE can open what the
    /// bridge (and hence this app's paired key) produces.
    static func encrypt(_ message: PushMessageContent, key: Data) throws -> String {
        let plain = try JSONEncoder().encode(message)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key))
        guard let combined = box.combined else { throw APNSCryptoError.badEncoding }
        return combined.base64EncodedString()
    }

    /// A fresh 32-byte key the bridge can hand out at pair time (base64).
    static func makeKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else { throw APNSCryptoError.badEncoding }
        return data
    }
}

enum APNSCryptoError: Error {
    case badEncoding
    case shortFrame
}
