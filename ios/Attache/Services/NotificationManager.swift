import Foundation
import UserNotifications
import UIKit

/// Local notifications with actionable Allow/Deny buttons.
///
/// While the app is running (foreground or briefly backgrounded) the WebSocket
/// delivers approval requests and we mirror them to the lock screen. Verdicts
/// from notification actions go through the bridge's REST `/verdict` endpoint
/// so they work even when the socket has been torn down.
///
/// True remote push (app fully suspended) needs the APNs relay described in
/// docs/notifications.md; the bridge can also POST to any webhook today.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private weak var app: AppModel?
    private let categoryId = NotificationCategory.approval

    func configure(app: AppModel) {
        self.app = app
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(
            identifier: "ALLOW", title: "Allow once", options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: "DENY", title: "Deny", options: [.destructive, .authenticationRequired]
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [allow, deny],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: Emission

    func notifyApproval(_ approval: ApprovalModel, host: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Approval · \(approval.tool)"
        content.body = approval.command ?? approval.reason
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = [
            "approvalId": approval.id,
            "sessionId": approval.sessionId,
            "host": host,
        ]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "approval-\(approval.id)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearApprovalNotification(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(id)"])
    }

    func notifyTurnDone(sessionTitle: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = sessionTitle.isEmpty ? "omp" : sessionTitle
        content.body = "Turn finished — the agent is waiting for you."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "turn-\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    func notifyAdvisor(sessionTitle: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Advisor · \(sessionTitle)"
        content.body = "The advisor flagged something on the working agent."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "advisor-\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let approvalId = userInfo["approvalId"] as? String else { return }
        let sessionId = userInfo["sessionId"] as? String
        let host = userInfo["host"] as? String

        switch response.actionIdentifier {
        case "ALLOW", "DENY":
            let verdict: Verdict = response.actionIdentifier == "ALLOW" ? .allow : .deny
            // The notification may have been rendered by the service extension
            // (host from the decrypted payload / app-group mirror) — resolve
            // the owning machine's token rather than the legacy single key.
            if let host, let token = AppSettings.bearerToken(forHost: host) {
                await BridgeClient.postVerdict(
                    host: host, token: token, sessionId: sessionId, approvalId: approvalId, verdict: verdict
                )
            }
            await MainActor.run {
                NotificationManager.shared.markResolvedLocally(approvalId: approvalId, verdict: verdict)
            }
        default:
            // Tapping the notification body opens the approvals queue.
            await MainActor.run {
                guard let app = NotificationManager.shared.app else { return }
                if !app.path.contains(.approvals) { app.path.append(.approvals) }
            }
        }
    }

    private func markResolvedLocally(approvalId: String, verdict: Verdict) {
        guard let app else { return }
        if let idx = app.approvals.firstIndex(where: { $0.id == approvalId }) {
            app.approvals[idx].status = verdict == .deny ? .denied : .allowed
        }
    }
}
