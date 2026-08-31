import SwiftUI
import WidgetKit

// MARK: - Timeline provider

/// Home-screen widgets read the app-group snapshot written by AppModel
/// (running sessions, pending approvals, today's cost). The app drives reloads
/// (`WidgetCenter.reloadAllTimelines`) whenever a value changes or the app
/// returns to foreground, so the provider never pretends to know a refresh
/// cadence — it always serves the latest stored snapshot for today.
struct SnapshotProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        var date: Date
        var snapshot: WidgetSnapshot
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WidgetSnapshotStore.read() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: .now, snapshot: WidgetSnapshotStore.read() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Home widgets

/// Widgets show what is happening on the paired machines right now: sessions
/// running, approvals awaiting a verdict, and what the active session has
/// spent today. Both small and medium families present the same three
/// signals at an appropriate density.
struct AttacheHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AttacheHomeWidget", provider: SnapshotProvider()) { entry in
            HomeWidgetView(entry: entry)
        }
        .configurationDisplayName("Attaché")
        .description("Running sessions, pending approvals and today's spend on your machines.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Rendering

struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotProvider.Entry

    var body: some View {
        Group {
            if entry.snapshot.paired {
                switch family {
                case .systemSmall:
                    smallLayout
                case .systemMedium:
                    mediumLayout
                default:
                    smallLayout
                }
            } else {
                unpairedState
            }
        }
        .containerBackground(for: .widget) {
            Theme.bg
        }
    }

    private var unpairedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("å")
                .font(Theme.mono(16, .bold))
                .foregroundStyle(Theme.accent)
            Text("Pair Attaché")
                .font(Theme.sans(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Open the app and pair a machine to show sessions here.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.text(0.45))
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("å")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.accent)
                Text("running")
                    .font(Theme.mono(9, .medium))
                    .foregroundStyle(Theme.text(0.55))
                Spacer()
                if entry.snapshot.pendingApprovals > 0 {
                    Circle().fill(Theme.warning).frame(width: 6, height: 6)
                }
            }
            Spacer()
            Text("\(entry.snapshot.runningSessions)")
                .font(Theme.mono(34, .bold))
                .foregroundStyle(Theme.text)
            Text("session\(entry.snapshot.runningSessions == 1 ? "" : "s") running")
                .font(Theme.sans(10.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 10)
            Divider().overlay(Theme.hairline)
            HStack {
                Text(entry.snapshot.pendingApprovals > 0
                    ? "\(entry.snapshot.pendingApprovals) approval\(entry.snapshot.pendingApprovals == 1 ? "" : "s") waiting"
                    : "no approvals pending")
                    .font(Theme.mono(9, .medium))
                    .foregroundStyle(entry.snapshot.pendingApprovals > 0 ? Theme.warning : Theme.success)
                Spacer()
                Text(String(format: "$%.2f", entry.snapshot.todayCostUSD))
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.text(0.8))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("å")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.accent)
                Text("Attaché")
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(entry.snapshot.pendingApprovals > 0 ? "NEEDS YOU" : "ALL CLEAR")
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(entry.snapshot.pendingApprovals > 0 ? Theme.warning : Theme.text(0.4))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke((entry.snapshot.pendingApprovals > 0 ? Theme.warning : Theme.text(0.25)).opacity(0.5))
                    )
            }
            .padding(.bottom, 12)
            HStack(spacing: 14) {
                statBlock(
                    value: "\(entry.snapshot.runningSessions)",
                    label: "running",
                    tint: entry.snapshot.runningSessions > 0 ? Theme.accent : Theme.text(0.5)
                )
                Divider().frame(height: 36).overlay(Theme.hairline)
                statBlock(
                    value: "\(entry.snapshot.pendingApprovals)",
                    label: "pending approvals",
                    tint: entry.snapshot.pendingApprovals > 0 ? Theme.warning : Theme.text(0.5)
                )
                Divider().frame(height: 36).overlay(Theme.hairline)
                statBlock(
                    value: String(format: "$%.2f", entry.snapshot.todayCostUSD),
                    label: "today",
                    tint: Theme.text(0.8)
                )
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private func statBlock(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.mono(20, .bold))
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(Theme.mono(8.5, .medium))
                .tracking(0.5)
                .foregroundStyle(Theme.text(0.4))
        }
    }
}

private extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        runningSessions: 2, pendingApprovals: 1, todayCostUSD: 1.24,
        updatedAt: .now, paired: true
    )
}
