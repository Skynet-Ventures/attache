import os
import UserNotifications

/// Notification Service Extension (contract H). The bridge encrypts payloads
/// with the per-device `pushKey` exchanged at pair time and hands the
/// ciphertext to the stateless relay; APNs delivers it here while the app is
/// suspended. We decrypt with the same key (stored in the app's keychain,
/// shared with this extension) and re-render the message:
///
///  - approvals reuse the app's APPROVAL category (Allow once / Deny actions),
///    with approvalId/sessionId/host in userInfo so the app's existing
///    NotificationManager can answer over the /verdict REST path;
///  - everything else renders as a plain notification.
///
/// On any failure (unknown key, malformed frame) the original APNs content is
/// presented unchanged — never a blank or dropped notification.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        guard
            let ciphertext = request.content.userInfo["ciphertext"] as? String,
            let keyBase64 = PushContext.pushKey,
            let key = Data(base64Encoded: keyBase64)
        else {
            finish(content)
            return
        }

        do {
            let message = try APNSCrypto.decrypt(payload: ciphertext, key: key)
            render(message, into: content)
        } catch {
            // Decryption is best-effort: surface whatever APNs delivered.
            os_log(.error, "Attaché push decrypt failed: %{public}@", "\(error)")
        }
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttempt {
            contentHandler(bestAttempt)
        }
    }

    private func render(_ message: PushMessageContent, into content: UNMutableNotificationContent) {
        content.title = message.title
        content.body = message.body
        content.sound = .default
        if message.kind == "approval", let approvalId = message.approvalId {
            content.categoryIdentifier = NotificationCategory.approval
            content.interruptionLevel = .timeSensitive
            content.userInfo["approvalId"] = approvalId
            content.userInfo["sessionId"] = message.sessionId ?? ""
            // Host drives the /verdict REST target back at the bridge.
            content.userInfo["host"] = message.host ?? PushContext.host ?? ""
        } else {
            content.categoryIdentifier = ""
        }
    }

    private func finish(_ content: UNNotificationContent) {
        if let contentHandler {
            contentHandler(content)
        }
        self.contentHandler = nil
        self.bestAttempt = nil
    }
}

/// Process-local access to the push secrets mirrored by the app. The keychain
/// key (`push.pushKey`) and the app-group host mirror (`bridge.host`) are
/// kept in sync by AppSettings.refreshPushContextMirror().
private enum PushContext {
    static var pushKey: String? {
        Keychain.read(key: PushSecrets.keychainKey)
    }

    static var host: String? {
        AttacheAppGroup.defaults?.string(forKey: AttacheAppGroup.hostKey)
    }
}
