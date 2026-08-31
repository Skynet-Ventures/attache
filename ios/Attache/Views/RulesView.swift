import SwiftUI

/// Review and revoke bridge-side "Always allow" approval rules.
struct RulesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AlwaysRuleModel] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Theme.accent)
                            Text("loading rules from bridge…")
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                    } else if rules.isEmpty {
                        VStack(spacing: 6) {
                            Text("No always-allow rules")
                                .font(Theme.sans(13, .medium))
                                .foregroundStyle(Theme.text(0.75))
                            Text("tapping “Always” on an approval creates one")
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.text(0.4))
                        }
                        .padding(.top, 30)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                                ruleRow(rule)
                                if idx < rules.count - 1 {
                                    Divider().overlay(Theme.hairlineFaint)
                                }
                            }
                        }
                        .background(Theme.raisedAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
                        Text("rules live on the bridge (~/.attache/rules.json) and auto-approve matching tool calls")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 12)
            }
        }
        .background(Theme.bg)
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            Text("Always-allow rules")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("\(rules.count)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private func ruleRow(_ rule: AlwaysRuleModel) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.tool)
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.accent)
                    if rule.pattern == nil {
                        Text("any call")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.warning.opacity(0.4)))
                    }
                }
                Text(rule.pattern ?? rule.note)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text(0.6))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("added \(String(rule.createdAt.prefix(10)))")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.text(0.3))
                    scopeBadge(rule.scope)
                }
            }
            Spacer()
            Button {
                app.engine?.deleteRule(id: rule.id)
                rules.removeAll { $0.id == rule.id }
            } label: {
                Text("revoke")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.danger.opacity(0.4)))
            }
            .buttonStyle(PressableStyle(scale: 0.94))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private func reload() async {
        rules = await app.engine?.listRules() ?? []
        loading = false
    }

    /// Scope badge (contract F): makes the rule's reach visible at a glance.
    private func scopeBadge(_ scope: RuleScope) -> some View {
        let (label, color): (String, Color) = switch scope.kind {
        case .global:
            ("everywhere", Theme.text(0.45))
        case .cwd:
            ("project", Theme.accent)
        case .session:
            ("this session", Theme.warning)
        }
        return Text(label)
            .font(Theme.mono(8.5, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4)))
    }
}
