import ActivityKit
import Foundation

/// Starts, updates, and ends the session Live Activity from AppModel state.
/// Called once per second from the app ticker; updates only on real changes.
///
/// Updates are local (app running / briefly backgrounded). Pushing updates
/// while suspended requires the APNs relay — see docs/notifications.md.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<AttacheActivityAttributes>?
    private var lastState: AttacheActivityAttributes.ContentState?
    private var activityTitle: String?

    func sync(app: AppModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let _ = app.sessionId, !app.sessionTitle.isEmpty else {
            end()
            return
        }

        let state = AttacheActivityAttributes.ContentState(
            statusLine: statusLine(app),
            ctxPercent: app.ctxPercent,
            costUsd: app.costUsd,
            turn: app.turnNo,
            liveAgents: app.liveAgentCount,
            pendingApprovals: app.pendingApprovalCount,
            isStreaming: app.turnActive || app.typing
        )

        if let activity, activityTitle == app.sessionTitle {
            guard state != lastState else { return }
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        // New session (or title changed): replace the activity.
        end()
        let attributes = AttacheActivityAttributes(
            sessionTitle: app.sessionTitle,
            machineName: app.machine.name
        )
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil)
        )
        activityTitle = app.sessionTitle
        lastState = state
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        activityTitle = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func statusLine(_ app: AppModel) -> String {
        if app.pendingApprovalCount > 0,
           let approval = app.approvals.first(where: { $0.status == .pending }) {
            return "waiting on approval · \(approval.command ?? approval.tool)"
        }
        if let lastTool = app.items.last(where: {
            if case .toolCard = $0.kind { return true }
            return false
        }), case .toolCard(let tool) = lastTool.kind, app.turnActive {
            return "\(tool.verb) \(tool.subject)"
        }
        if app.turnActive || app.typing { return "agent working · turn \(app.turnNo)" }
        return "idle · turn \(app.turnNo)"
    }
}
