import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Model roles — tap level to cycle")
                        .padding(.bottom, 7)
                    rolesCard
                        .padding(.bottom, 12)
                    SectionHeader(title: "Fallback chain — default")
                        .padding(.bottom, 7)
                    fallbackCard
                        .padding(.bottom, 12)
                    SectionHeader(title: "Behavior")
                        .padding(.bottom, 7)
                    behaviorCard
                        .padding(.bottom, 12)
                    SectionHeader(title: "Notifications — away from home")
                        .padding(.bottom, 7)
                    WebhookCard()
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            Text("Models & settings")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("global profile")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var rolesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(app.roles.enumerated()), id: \.element.id) { idx, role in
                HStack(spacing: 0) {
                    Text(role.name)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(role.name == "default" ? Theme.accent : role.name == "advisor" ? Theme.warning : Theme.text(0.6))
                        .frame(width: 74, alignment: .leading)
                    Text(role.model)
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        app.engine?.cycleThinking(role: role.name)
                    } label: {
                        Text(role.thinking.rawValue)
                            .font(Theme.mono(9, .medium))
                            .foregroundStyle(role.name == "default" ? Theme.accent : Theme.text(0.55))
                            .frame(minWidth: 34)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(role.name == "default" ? Theme.accent.opacity(0.45) : Color.white.opacity(0.18))
                            )
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                if idx < app.roles.count - 1 {
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                fallbackChip("deepseek-v4-flash", primary: true)
                Text("→").font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                fallbackChip("nemotron-3-ultra", primary: false)
                Text("→").font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
            }
            fallbackChip("glm-5.2", primary: false)
            Text("on 429 / quota — session never dies")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    private func fallbackChip(_ label: String, primary: Bool) -> some View {
        Text(label)
            .font(Theme.mono(10.5, .medium))
            .foregroundStyle(primary ? Theme.text : Theme.text(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: 0x17171A))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(primary ? Theme.accent.opacity(0.45) : Color.white.opacity(0.12))
            )
    }

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Approval mode")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                approvalModeSegmented
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            Divider().overlay(Theme.hairlineFaint)
            HStack {
                Text("Hindsight memory")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.text)
                Spacer()
                hindsightToggle
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            Divider().overlay(Theme.hairlineFaint)
            settingRow("Snapcompact", value: "auto @ 85%")
            Divider().overlay(Theme.hairlineFaint)
            Button {
                app.path.append(.rules)
            } label: {
                settingRow("Always-allow rules", value: "review ▸")
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.hairlineFaint)
            settingRow("MCP servers", value: "\(app.mcpSummary) ▸")
            Divider().overlay(Theme.hairlineFaint)
            settingRow("Skills & extensions", value: "\(app.skillsSummary) ▸")
        }
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    private var approvalModeSegmented: some View {
        HStack(spacing: 0) {
            ForEach(ApprovalModeSetting.allCases, id: \.self) { mode in
                Button {
                    app.engine?.setApprovalMode(mode)
                } label: {
                    Text(mode.label)
                        .font(Theme.mono(10, app.approvalMode == mode ? .semibold : .medium))
                        .foregroundStyle(app.approvalMode == mode ? .black : Theme.text(0.45))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(app.approvalMode == mode ? Theme.accent : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.codeBlock)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairlineStrong))
    }

    private var hindsightToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                app.engine?.toggleHindsight()
            }
        } label: {
            ZStack(alignment: app.hindsightEnabled ? .trailing : .leading) {
                Capsule()
                    .fill(app.hindsightEnabled ? Theme.accent : Color.white.opacity(0.14))
                    .frame(width: 40, height: 24)
                Circle()
                    .fill(.black)
                    .overlay(Circle().stroke(Color.white.opacity(0.2)))
                    .frame(width: 20, height: 20)
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
    }

    private struct WebhookCard: View {
        @Environment(AppModel.self) private var app
        @State private var url = ""
        @State private var status: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("When no device is connected, the bridge POSTs approvals and turn-done alerts here — e.g. an ntfy.sh topic you subscribe to in the ntfy app.")
                    .font(Theme.sans(11))
                    .foregroundStyle(Theme.text(0.5))
                    .lineSpacing(3)
                TextField("https://ntfy.sh/your-private-topic", text: $url)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.accent)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(Theme.codeBlock)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                HStack(spacing: 8) {
                    Button {
                        Task {
                            let ok = await app.engine?.registerWebhook(url.trimmingCharacters(in: .whitespaces)) ?? false
                            status = ok ? (url.isEmpty ? "webhook removed" : "saved to bridge") : "couldn't reach bridge"
                        }
                    } label: {
                        Text("Save")
                            .font(Theme.sans(12, .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(PressableStyle())
                    Button {
                        Task {
                            let ok = await app.engine?.testWebhook() ?? false
                            status = ok ? "test sent — check your ntfy app" : "test failed — save a URL first"
                        }
                    } label: {
                        Text("Send test")
                            .font(Theme.sans(12, .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let status {
                    Text(status)
                        .font(Theme.mono(10))
                        .foregroundStyle(status.contains("fail") || status.contains("couldn't") ? Theme.danger : Theme.success)
                }
            }
            .padding(13)
            .background(Theme.raisedAlt)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
            .onAppear { url = app.webhookURL }
        }
    }

    private func settingRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(value)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text(0.5))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
