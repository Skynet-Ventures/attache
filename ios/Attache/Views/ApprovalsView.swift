import SwiftUI

struct ApprovalsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 11) {
                    ForEach(app.approvals) { approval in
                        QueueCard(approval: approval)
                    }
                    if app.pendingApprovalCount == 0 {
                        VStack(spacing: 6) {
                            Text("✓")
                                .font(Theme.mono(22, .semibold))
                                .foregroundStyle(Theme.success)
                            Text("Queue clear")
                                .font(Theme.sans(13, .medium))
                                .foregroundStyle(Theme.text(0.75))
                            Text("agents resume automatically")
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.text(0.4))
                        }
                        .padding(.top, 26)
                        .padding(.bottom, 6)
                    }
                    Text("answers sync to the TUI instantly")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            (Text("Approvals ").foregroundStyle(Theme.text)
                + Text("· \(app.pendingApprovalCount)").foregroundStyle(Theme.warning))
                .font(Theme.sans(15, .semibold))
            Spacer()
            Text("policy: \(app.approvalMode.label)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }
}

private struct QueueCard: View {
    @Environment(AppModel.self) private var app
    let approval: ApprovalModel

    private var resolved: Bool { approval.status != .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(approval.riskDetail)
                    .font(Theme.mono(9.5, .semibold))
                    .foregroundStyle(riskColor)
                Text(approval.source)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.text(0.4))
                Spacer()
            }
            .padding(.bottom, 7)
            if !approval.diffLines.isEmpty {
                // Proper review: per-file collapsible sections, tinting, scroll.
                DiffSectionsView(sections: DiffSections.sections(from: approval.diffLines), fontSize: 10)
                    .padding(.bottom, 5)
            } else if let command = approval.command {
                // No diff detected — plain text blob, exactly as before.
                Text(command)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBlock)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(.bottom, 5)
            }
            Text(approval.reason)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.text(0.5))
                .padding(.bottom, 9)
            if resolved {
                HStack(spacing: 7) {
                    Text(approval.status == .denied ? "✕" : "✓")
                    Text(verdictText)
                    Text("· synced to TUI")
                        .fontWeight(.regular)
                        .foregroundStyle(Theme.textFaint)
                }
                .font(Theme.mono(11, .medium))
                .foregroundStyle(approval.status == .denied ? Theme.danger : Theme.success)
            } else {
                ApprovalButtons(height: 30) { verdict in
                    withAnimation(.easeOut(duration: 0.3)) {
                        app.engine?.resolveApproval(id: approval.id, verdict: verdict)
                    }
                } onAlways: { scope in
                    withAnimation(.easeOut(duration: 0.3)) {
                        app.engine?.resolveApproval(id: approval.id, verdict: .allowAlways, scope: scope)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline))
        .opacity(resolved ? 0.62 : 1)
    }

    private var riskColor: Color {
        switch approval.risk {
        case .high: Theme.danger
        case .medium: Theme.warning
        case .low: Theme.success
        }
    }

    private var verdictText: String {
        switch approval.status {
        case .denied: "denied"
        case .always: "allowed · rule saved"
        default: "allowed once"
        }
    }
}
