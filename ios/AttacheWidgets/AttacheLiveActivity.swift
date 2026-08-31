import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen Live Activity + Dynamic Island for a running omp session,
/// per the design handoff's "system surfaces" frame (direction 1a).
struct AttacheLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AttacheActivityAttributes.self) { context in
            LockScreenCard(context: context)
                .activityBackgroundTint(Color(hex: 0x0C0C0E))
                .activitySystemActionForegroundColor(Theme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("å")
                        .font(Theme.mono(15, .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(context.state.isStreaming ? Theme.accent : Theme.success)
                            .frame(width: 6, height: 6)
                        Text("T\(context.state.turn)")
                            .font(Theme.mono(11, .semibold))
                            .foregroundStyle(Theme.text(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.sessionTitle)
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.statusLine)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.text(0.6))
                            .lineLimit(1)
                        ProgressView(value: min(context.state.ctxPercent, 100), total: 100)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                            .frame(height: 3)
                        HStack {
                            Text(metaLine(context.state))
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.text(0.45))
                            Spacer()
                            if context.state.pendingApprovals > 0 {
                                Text("\(context.state.pendingApprovals) approval\(context.state.pendingApprovals == 1 ? "" : "s") waiting")
                                    .font(Theme.mono(9.5, .semibold))
                                    .foregroundStyle(Theme.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(Theme.warning.opacity(0.4))
                                    )
                            }
                        }
                    }
                }
            } compactLeading: {
                Text("å")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.accent)
            } compactTrailing: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(compactDotColor(context.state))
                        .frame(width: 6, height: 6)
                    Text("T\(context.state.turn)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.text(0.8))
                }
            } minimal: {
                Circle()
                    .fill(compactDotColor(context.state))
                    .frame(width: 8, height: 8)
            }
            .keylineTint(Theme.accent)
        }
    }

    private func compactDotColor(_ state: AttacheActivityAttributes.ContentState) -> Color {
        if state.pendingApprovals > 0 { return Theme.warning }
        return state.isStreaming ? Theme.accent : Theme.success
    }

    private func metaLine(_ state: AttacheActivityAttributes.ContentState) -> String {
        var parts = [
            "ctx \(Int(state.ctxPercent))%",
            String(format: "$%.2f", state.costUsd),
        ]
        if state.liveAgents > 0 { parts.append("\(state.liveAgents) agents") }
        return parts.joined(separator: " · ")
    }
}

private struct LockScreenCard: View {
    let context: ActivityViewContext<AttacheActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(context.state.pendingApprovals > 0 ? Theme.warning : (context.state.isStreaming ? Theme.accent : Theme.success))
                    .frame(width: 7, height: 7)
                Text(context.attributes.sessionTitle)
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(context.state.isStreaming ? "RUNNING" : (context.state.pendingApprovals > 0 ? "NEEDS YOU" : "IDLE"))
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(context.state.isStreaming ? Theme.accent : (context.state.pendingApprovals > 0 ? Theme.warning : Theme.text(0.5)))
            }
            .padding(.bottom, 6)
            Text(context.state.statusLine)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.text(0.6))
                .lineLimit(1)
                .padding(.bottom, 9)
            ProgressView(value: min(context.state.ctxPercent, 100), total: 100)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 3)
                .padding(.bottom, 7)
            HStack(spacing: 10) {
                Text("turn \(context.state.turn)")
                Text("ctx \(Int(context.state.ctxPercent))%")
                Text(String(format: "$%.2f", context.state.costUsd))
                if context.state.liveAgents > 0 {
                    Text("\(context.state.liveAgents) agents live")
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Text(context.attributes.machineName)
            }
            .font(Theme.mono(9.5))
            .foregroundStyle(Theme.text(0.45))
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }
}
