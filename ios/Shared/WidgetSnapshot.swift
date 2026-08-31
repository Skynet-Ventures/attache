import Foundation

/// The shared app group. The app writes the widget snapshot and the bridge
/// host mirror here; home-screen widgets and the notification service
/// extension (separate processes) read them back.
enum AttacheAppGroup {
    static let id = "group.io.skynetventures.attache"
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
    /// Mirror of the paired bridge address — the NSE needs it to build the
    /// /verdict REST call the approval actions perform in the app.
    static let hostKey = "bridge.host"
}

/// Value snapshot of what the home-screen widgets may render. Written by the
/// app under `widget.snapshot` in the shared app group whenever the values
/// change; read-only for the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    var runningSessions: Int
    var pendingApprovals: Int
    var todayCostUSD: Double
    var updatedAt: Date
    /// False before any machine has been paired — widgets show a pairing hint.
    var paired: Bool

    static let empty = WidgetSnapshot(
        runningSessions: 0, pendingApprovals: 0, todayCostUSD: 0,
        updatedAt: .distantPast, paired: false
    )
}

enum WidgetSnapshotStore {
    private static let storageKey = "widget.snapshot"

    static func read() -> WidgetSnapshot? {
        guard let data = AttacheAppGroup.defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot to the app group and reports whether anything
    /// changed — the app only reloads widget timelines on an actual change.
    @discardableResult
    static func publishIfChanged(_ snapshot: WidgetSnapshot) -> Bool {
        guard snapshot != read() else { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        AttacheAppGroup.defaults?.set(data, forKey: storageKey)
        return true
    }
}
