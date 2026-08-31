import SwiftUI

struct PlanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showRefineInput = false
    @State private var refineText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            if let plan = app.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        draftNotice(plan)
                        SectionHeader(title: "Steps · \(plan.steps.count)")
                        stepsCard(plan)
                        stateBanner(plan)
                        if case .ready = plan.state {
                            actionRow
                        }
                        Text("accepting pins the plan as a goal — /goal semantics apply")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, Theme.streamGutter)
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
                Text("No plan waiting")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
        }
        .background(Theme.bg)
        .alert("Refine plan", isPresented: $showRefineInput) {
            TextField("What should change?", text: $refineText)
            Button("Send") {
                app.engine?.planRefine(refineText)
                refineText = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.plan?.title ?? "Plan")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.text)
                    .kerning(-0.15)
                    .lineLimit(1)
                Text(app.plan?.roleLabel ?? "")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text(badge.0)
                .font(Theme.mono(9.5, .medium))
                .foregroundStyle(badge.1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.14)))
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var badge: (String, Color) {
        switch app.plan?.state {
        case .executing: ("EXECUTING", Theme.accent)
        case .rejected: ("REJECTED", Theme.danger)
        case .refining: ("REFINING", Theme.warning)
        default: ("NEEDS YOU", Theme.warning)
        }
    }

    private func draftNotice(_ plan: PlanModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("READ-ONLY DRAFT — NOTHING RAN YET")
                .font(Theme.mono(9.5, .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text(0.4))
            Text(plan.summary)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.text(0.8))
                .lineSpacing(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline))
    }

    private func stepsCard(_ plan: PlanModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { idx, step in
                HStack(spacing: 10) {
                    Text(markSymbol(step.mark))
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(markColor(step.mark))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(String(format: "%02d", idx + 1)) · \(step.title)")
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(step.file)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.text(0.4))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(step.risk.label)
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(riskColor(step.risk))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                if idx < plan.steps.count - 1 {
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    @ViewBuilder
    private func stateBanner(_ plan: PlanModel) -> some View {
        switch plan.state {
        case .refining:
            Text("refinement requested — plan re-drafting on \(app.machine.name), ~40s")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warning.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warning.opacity(0.3)))
        case .rejected:
            HStack(spacing: 10) {
                Text("plan rejected — nothing was executed")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.danger)
                Spacer()
                Button("Request new draft") {
                    app.engine?.planRequestRedraft()
                }
                .font(Theme.sans(11, .medium))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
            }
        case .executing(let step):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BlinkDot(color: Theme.accent, size: 6)
                    Text("handed to executor · step \(step)/\(plan.steps.count)")
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button("pause") { app.engine?.goalPause() }
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.text(0.6))
                        .buttonStyle(.plain)
                }
                ContextBar(percent: Double(step - 1) / Double(max(1, plan.steps.count)) * 100)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.35)))
        case .ready:
            EmptyView()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                app.engine?.planReject()
            } label: {
                Text("Reject")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.text(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.15)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                showRefineInput = true
            } label: {
                Text("Refine…")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.text(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.15)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                app.engine?.planAccept()
            } label: {
                Text("Accept & execute")
                    .font(Theme.sans(12, .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(PressableStyle(scale: 0.97))
        }
    }

    private func markSymbol(_ mark: PlanStepModel.Mark) -> String {
        switch mark {
        case .done: "✓"
        case .active: "●"
        case .pending: "·"
        }
    }

    private func markColor(_ mark: PlanStepModel.Mark) -> Color {
        switch mark {
        case .done: Theme.success
        case .active: Theme.accent
        case .pending: Theme.text(0.3)
        }
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .high: Theme.danger
        case .medium: Theme.warning
        case .low: Theme.success
        }
    }
}
