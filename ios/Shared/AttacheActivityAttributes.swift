import ActivityKit
import Foundation

/// Shared between the app (starts/updates activities) and the widget
/// extension (renders them). Mirrors the "system surfaces" design frame.
struct AttacheActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// One-line status: current tool or turn state ("editing pool.go", "waiting on approval…").
        var statusLine: String
        var ctxPercent: Double
        var costUsd: Double
        var turn: Int
        var liveAgents: Int
        var pendingApprovals: Int
        var isStreaming: Bool
    }

    var sessionTitle: String
    var machineName: String
}
