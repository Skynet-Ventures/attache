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
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(app.subagents) { agent in
                        AgentTile(agent: agent, focused: app.focusedAgent?.id == agent.id)
                            .onTapGesture { app.focusedAgentId = agent.id }
                    }
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 12)
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
                app.engine?.dispatchSubagent(task: task)
            }
            Button("Cancel", role: .cancel) { dispatchTask = "" }
        } message: {
            Text("Asks the primary agent to spin up a task-tool subagent for this.")
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
                        Text("\(agent.handle) · task model")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.text(0.4))
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
