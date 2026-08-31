import SwiftUI

struct AgentsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var steerDraft = ""
    @State private var showDispatch = false
    @State private var dispatchTask = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(app.subagents) { agent in
                            AgentTile(agent: agent, focused: app.focusedAgent?.id == agent.id)
                                .onTapGesture { app.focusedAgentId = agent.id }
                        }
                    }
                    CommsFeedSection()
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            focusedSheet
        }
        .background(Theme.bg)
        .alert("Dispatch a subagent", isPresented: $showDispatch) {
            TextField("what should it work on?", text: $dispatchTask)
            Button("Dispatch") {
                let task = dispatchTask.trimmingCharacters(in: .whitespaces)
                dispatchTask = ""
                guard !task.isEmpty else { return }
                app.engine?.dispatchSubagent(task: task, isolated: false)
            }
            Button("Dispatch isolated") {
                let task = dispatchTask.trimmingCharacters(in: .whitespaces)
                dispatchTask = ""
                guard !task.isEmpty else { return }
                app.engine?.dispatchSubagent(task: task, isolated: true)
            }
            Button("Cancel", role: .cancel) { dispatchTask = "" }
        } message: {
            Text("Asks the primary agent to spin up a task-tool subagent for this. Isolated runs work in a snapshot workspace and leave a reviewable patch.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text("Agents")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                showDispatch = true
            } label: {
                Text("+ dispatch")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var subtitle: String {
        let live = app.subagents.filter { $0.status == .live }.count
        let done = app.subagents.filter { $0.status == .done }.count
        let queued = app.subagents.filter { $0.status == .queued }.count
        let title = app.sessionTitle.isEmpty ? "session" : app.sessionTitle.lowercased()
        return "\(title) · \(live) live · \(done) done · \(queued) queued"
    }

    private var focusedSheet: some View {
        Group {
            if let agent = app.focusedAgent {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 36, height: 4)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                    HStack(spacing: 8) {
                        if agent.status == .live {
                            BlinkDot(color: Theme.accent, size: 6)
                        } else {
                            Circle().fill(agent.status == .done ? Theme.success : Theme.text(0.3)).frame(width: 6, height: 6)
                        }
                        Text(agent.name)
                            .font(Theme.mono(12.5, .semibold))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        if agent.hasPatch {
                            Button {
                                app.engine?.viewSubagentPatch(id: agent.id)
                            } label: {
                                Text("review patch ▸\(agent.patchBytes > 0 ? " \(patchSizeLabel(agent.patchBytes))" : "")")
                                    .font(Theme.mono(9.5, .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accentBorder))
                            }
                            .buttonStyle(PressableStyle(scale: 0.94))
                        } else {
                            Text("\(agent.handle) · task model")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.text(0.4))
                        }
                    }
                    .padding(.bottom, 10)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(agent.transcript) { line in
                                SubagentLineView(line: line)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxHeight: 190)
                    .padding(.bottom, 10)
                    HStack(spacing: 8) {
                        TextField("Steer \(agent.name)…", text: $steerDraft)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.text)
                            .tint(Theme.accent)
                            .onSubmit(sendSteer)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
                        Button(action: sendSteer) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                    }
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.bottom, 12)
                .background(Theme.raisedAlt)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                        .stroke(Theme.hairlineStrong),
                    alignment: .top
                )
                .shadow(color: .black.opacity(0.6), radius: 15, y: -12)
            }
        }
    }

    private func patchSizeLabel(_ bytes: Int) -> String {
        bytes >= 1024 ? "\(bytes / 1024)kb" : "\(bytes)b"
    }

    private func sendSteer() {
        guard let agent = app.focusedAgent else { return }
        let text = steerDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        steerDraft = ""
        app.engine?.steerSubagent(id: agent.id, text: text)
    }
}

private struct AgentTile: View {
    let agent: SubagentModel
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(dotSymbol)
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(dotColor)
                Text(agent.name)
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.bottom, 4)
            Text(agent.lastLine)
                .font(Theme.sans(11))
                .foregroundStyle(Theme.text(0.6))
                .lineSpacing(2.5)
                .lineLimit(2, reservesSpace: true)
            Text(agent.meta)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .padding(.top, 7)
            if let isolation = agent.isolationLabel {
                Text(isolation)
                    .font(Theme.mono(8.5, .medium))
                    .foregroundStyle(Theme.text(0.55))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.14)))
                    .padding(.top, 6)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
        .opacity(opacity)
    }

    private var dotSymbol: String {
        switch agent.status {
        case .live: "●"
        case .done: "✓"
        case .queued: "○"
        }
    }

    private var dotColor: Color {
        switch agent.status {
        case .live: Theme.accent
        case .done: Theme.success
        case .queued: Theme.text(0.4)
        }
    }

    private var borderColor: Color {
        if focused { return Theme.accent }
        switch agent.status {
        case .live: return Theme.accent.opacity(0.4)
        case .done: return Theme.hairline
        case .queued: return Color.white.opacity(0.14)
        }
    }

    private var opacity: Double {
        switch agent.status {
        case .live: 1
        case .done: 0.85
        case .queued: 0.7
        }
    }
}

private struct SubagentLineView: View {
    let line: SubagentLine

    var body: some View {
        switch line.kind {
        case .tool:
            HStack(spacing: 8) {
                Text("✓").font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.success)
                Text(line.text)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text(0.65))
                    .lineLimit(1)
                Spacer()
                Text(line.meta)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.text(0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.searchField)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07)))
        case .text:
            Text(line.text)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.text(0.75))
                .lineSpacing(3)
        case .steer:
            HStack(alignment: .top, spacing: 7) {
                Text("»").foregroundStyle(Theme.accent)
                Text(line.text).foregroundStyle(Theme.accent.opacity(0.85))
            }
            .font(Theme.mono(10.5))
            .lineSpacing(3)
        }
    }
}

// MARK: - Comms feed (hub passthrough)

/// Chronological hub feed surfaced under the agents screen: omp `irc_message`,
/// `notice` and `goal_updated` events from the raw stream passthrough. Sender
/// badges distinguish authors; goal changes are highlighted.
struct CommsFeedSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("COMMS")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.text(0.4))
                Spacer()
                Text("live passthrough")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.bottom, 7)
            if app.hubFeed.isEmpty {
                Text("no comms yet — hub messages, notices and goal changes land here")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(app.hubFeed.suffix(50)) { message in
                        CommsRow(message: message)
                    }
                }
            }
        }
    }
}

private struct CommsRow: View {
    let message: HubMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                if message.kind == .goal, let objective = message.goalObjective, !objective.isEmpty {
                    Text(objective)
                        .font(Theme.sans(11, .medium))
                        .foregroundStyle(Theme.text(0.95))
                        .lineLimit(2)
                }
                Text(message.text)
                    .font(message.kind == .goal ? Theme.sans(11.5, .medium) : Theme.sans(11.5))
                    .foregroundStyle(message.kind == .goal ? Theme.text(0.9) : Theme.text(0.7))
                    .lineSpacing(2.5)
                    .lineLimit(4)
            }
            Spacer(minLength: 6)
            Text(age)
                .font(Theme.mono(8.5))
                .foregroundStyle(Theme.text(0.3))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.kind == .goal ? Theme.accent.opacity(0.08) : Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(message.kind == .goal ? Theme.accentBorderFaint : Theme.hairlineFaint)
        )
    }

    @ViewBuilder
    private var badge: some View {
        switch message.kind {
        case .message:
            if let sender = message.sender {
                Text(sender)
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color(for: sender))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("agent")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.text(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.14)))
            }
        case .goal:
            Text("◎ GOAL")
                .font(Theme.mono(9, .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accentBorder))
        case .notice:
            Text(noticeSymbol)
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(noticeColor)
        }
    }

    private var noticeSymbol: String {
        message.level == "error" ? "✕" : message.level == "warning" ? "!" : "◆"
    }

    private var noticeColor: Color {
        switch message.level {
        case "error": Theme.danger
        case "warning": Theme.warning
        default: Theme.text(0.5)
        }
    }

    private func color(for sender: String) -> Color {
        let palette: [Color] = [
            Theme.accent, Theme.success, Theme.warning, Theme.danger,
            Color(hex: 0x5AC8FA), Color(hex: 0xBF5AF2),
        ]
        var h = 0
        for scalar in sender.unicodeScalars {
            h = (h &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        return palette[h % palette.count]
    }

    private var age: String {
        let secs = max(0, -message.timestamp.timeIntervalSinceNow)
        if secs < 90 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }
}
