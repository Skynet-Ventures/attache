import SwiftUI

/// Renders one item in the live turn stream.
struct ChatItemView: View {
    @Environment(AppModel.self) private var app
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(markdownish(text))
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Theme.userBubble)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 14,
                        bottomTrailingRadius: 4, topTrailingRadius: 14
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                if let entryId = item.entryId {
                    Button {
                        app.engine?.branch(entryId: entryId, preview: messagePreview(text))
                    } label: {
                        Label("Branch here — fork a new session", systemImage: "arrow.triangle.branch")
                    }
                }
            }

        case .agentText(let text):
            Text(markdownish(text))
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text(0.8))
                .lineSpacing(3.5)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let text):
            Text(text)
                .font(Theme.sans(12).italic())
                .foregroundStyle(Theme.textFaint)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .steer(let text):
            HStack(alignment: .top, spacing: 7) {
                Text("»").foregroundStyle(Theme.accent)
                Text(text).foregroundStyle(Theme.text(0.5))
            }
            .font(Theme.mono(11))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .notice(let text):
            HStack(alignment: .top, spacing: 7) {
                Text("◆").foregroundStyle(Theme.accent.opacity(0.7))
                Text(text).foregroundStyle(Theme.accent.opacity(0.7))
            }
            .font(Theme.mono(10))
            .frame(maxWidth: .infinity, alignment: .leading)

        case .toolCard(let tool):
            ToolCardView(tool: tool)

        case .advisor(let note):
            AdvisorBlock(itemId: item.id, note: note)

        case .approval(let approval):
            if approval.status == .pending {
                InlineApprovalCard(approval: approval)
            } else {
                ResolvedInlineApproval(approval: approval)
            }

        case .dialog(let dialog):
            DialogCard(itemId: item.id, dialog: dialog)

        case .queued(let queued):
            QueuedItemView(itemId: item.id, queued: queued)
        }
    }

    private func markdownish(_ text: String) -> AttributedString {
        MarkdownCache.render(text)
    }

    private func messagePreview(_ text: String) -> String {
        String(text.prefix(64))
    }
}

// MARK: - Queued offline prompt

/// A send made while the bridge was unreachable. Stays in the stream until it
/// flushes on reconnect; long-press to drop it from the queue.
struct QueuedItemView: View {
    @Environment(AppModel.self) private var app
    let itemId: String
    let queued: QueuedPrompt

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("⧗")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("queued — sends when \(app.machine.name) reconnects")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.warning.opacity(0.7))
                Text(queued.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text(0.55))
                    .lineSpacing(3)
                    .lineLimit(3)
                if queued.hasAttachments {
                    Text("📎 \(queued.attachmentCount) attachment\(queued.attachmentCount == 1 ? "" : "s")")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.text(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(role: .destructive) {
                app.engine?.removeQueuedPrompt(id: itemId)
            } label: {
                Label("Remove from queue", systemImage: "trash")
            }
        }
    }
}

// MARK: - Tool card

struct ToolCardView: View {
    let tool: ToolCardModel
    @Environment(AppModel.self) private var app
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                if tool.running {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                } else {
                    Text(tool.icon)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(tool.iconIsAccent ? Theme.accent : Theme.success)
                }
                (Text(tool.verb).foregroundStyle(Theme.text(tool.hasDiff ? 0.85 : 0.7))
                    + Text(" \(tool.subject)").foregroundStyle(Theme.text(tool.hasDiff ? 0.45 : 0.4)))
                    .font(Theme.mono(11, .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if tool.running, ["hub", "task"].contains(tool.verb), !app.subagents.isEmpty {
                    // A hub/task call blocks the primary while subagents work —
                    // surface their liveness here and link to the hub.
                    Button {
                        if !app.path.contains(.agents) { app.path.append(.agents) }
                    } label: {
                        Text(subagentSummary)
                            .font(Theme.mono(9.5, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                } else if let add = tool.addCount, let del = tool.delCount {
                    Text("+\(add)").font(Theme.mono(10, .medium)).foregroundStyle(Theme.success)
                    Text("−\(del)").font(Theme.mono(10, .medium)).foregroundStyle(Theme.danger)
                } else if !tool.meta.isEmpty {
                    Text(tool.meta).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                }
                if let hash = tool.hashline {
                    Text(hash)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.text(0.3))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
                } else if !tool.detailLines.isEmpty {
                    Text(expanded ? "▴" : "▾")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            // Detail lines (diff preview keeps a collapsed core, like Ctrl+O)
            if !tool.detailLines.isEmpty {
                let lines = visibleLines
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            DiffLineView(line: line, fontSize: 10.5)
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairlineFaint), alignment: .top)
                }
            }

            if let footer = tool.footer {
                HStack(spacing: 10) {
                    Text(footer)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.success)
                        .lineLimit(1)
                    Spacer()
                    Text(expanded ? "tap to collapse" : "tap to expand")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.text(0.4))
                    if tool.hasDiff {
                        Button {
                            app.diff = diffScreenModel()
                            app.path.append(.diff)
                        } label: {
                            Text("review ▸")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairlineFaint), alignment: .top)
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    /// Collapsed diff cards keep the hot hunk visible (like the prototype's
    /// edit card); everything shows when expanded.
    private var subagentSummary: String {
        let live = app.subagents.filter { $0.status == .live }.count
        let done = app.subagents.filter { $0.status == .done }.count
        if live > 0 { return "\(live) live · \(done) done ▸" }
        return "\(done) done ▸"
    }

    private var visibleLines: [DiffLine] {
        if expanded { return tool.detailLines }
        if tool.hasDiff {
            // Show the contiguous run around the first added line.
            guard let first = tool.detailLines.firstIndex(where: { $0.kind == .add && !$0.text.hasPrefix("+const") }) else {
                return Array(tool.detailLines.prefix(5))
            }
            let lo = max(0, first - 1)
            let hi = min(tool.detailLines.count, first + 4)
            return Array(tool.detailLines[lo..<hi])
        }
        return []
    }

    private func diffScreenModel() -> DiffScreenModel {
        let path = tool.subject
        let file = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        return DiffScreenModel(
            fileName: file.isEmpty ? path : file,
            directory: dir.isEmpty ? "" : "\(dir) · hashline-anchored edit",
            addCount: tool.addCount ?? 0,
            delCount: tool.delCount ?? 0,
            hashline: tool.hashline ?? "",
            lines: tool.detailLines,
            footer: tool.footer ?? ""
        )
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var fontSize: CGFloat = 11

    var body: some View {
        Text(line.text)
            .font(Theme.mono(fontSize))
            .foregroundStyle(color)
            .lineSpacing(fontSize * 0.6)
            .padding(.horizontal, 11)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var color: Color {
        switch line.kind {
        case .add: Theme.diffAddText
        case .del: Theme.diffDelText
        case .hunk: Theme.textFaint
        case .context: Theme.text(0.5)
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: Theme.diffAddBg
        case .del: Theme.diffDelBg
        default: .clear
        }
    }
}

// MARK: - Folded tool run

/// A folded run of consecutive completed tool cards. Collapsed it shows one
/// summary row; expanded it renders each card inline (each individually
/// expandable for its diff). Streaming tools never appear here — the grouping
/// logic keeps in-flight cards visible on their own.
struct ToolRunCard: View {
    let group: ToolRunGroup
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(group.toolCount) tools ran")
                            .font(Theme.mono(11.5, .semibold))
                            .foregroundStyle(Theme.text(0.85))
                        Text(summary)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.text(0.4))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(expanded ? "▴" : "▾")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 8) {
                    ForEach(group.tools.indices, id: \.self) { idx in
                        ToolCardView(tool: group.tools[idx])
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairlineFaint), alignment: .top)
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private var summary: String {
        let verbs = group.tools.prefix(3).map(\.verb)
        if group.toolCount > 3 {
            return "\(verbs.joined(separator: ", ")) · +\(group.toolCount - 3) more · tap to review"
        }
        return verbs.joined(separator: ", ")
    }
}

// MARK: - Per-file diff sections

/// Proper diff review surface: per-file collapsible sections, add/del line
/// tinting, and horizontal scrolling so long lines never wrap the card.
/// Falls back to the caller's text blob when no sections exist.
struct DiffSectionsView: View {
    let sections: [DiffFileSection]
    var fontSize: CGFloat = 10.5
    /// File paths the user collapsed (folded by path so state survives
    /// recomputation of the underlying model).
    @State private var collapsedPaths: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        toggle(section.path)
                    } label: {
                        HStack(spacing: 7) {
                            Text(collapsedPaths.contains(section.path) ? "▸" : "▾")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textFaint)
                            Text(section.path)
                                .font(Theme.mono(10.5, .semibold))
                                .foregroundStyle(Theme.text(0.85))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if section.addCount > 0 {
                                Text("+\(section.addCount)")
                                    .font(Theme.mono(9.5, .medium))
                                    .foregroundStyle(Theme.success)
                            }
                            if section.delCount > 0 {
                                Text("−\(section.delCount)")
                                    .font(Theme.mono(9.5, .medium))
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBlock.opacity(0.55))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !collapsedPaths.contains(section.path) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(section.lines) { line in
                                    DiffLineView(line: line, fontSize: fontSize)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineFaint))
            }
        }
    }

    private func toggle(_ path: String) {
        if collapsedPaths.contains(path) { collapsedPaths.remove(path) } else { collapsedPaths.insert(path) }
    }
}

// MARK: - Advisor block

struct AdvisorBlock: View {
    @Environment(AppModel.self) private var app
    let itemId: String
    let note: AdvisorNoteModel

    var body: some View {
        switch note.state {
        case .dismissed:
            EmptyView()
        case .addressed:
            HStack(spacing: 7) {
                Text("◆")
                Text("advisor note forwarded to agent as steer")
            }
            .font(Theme.mono(10))
            .foregroundStyle(Theme.accent.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .open:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text("◆ ADVISOR")
                        .font(Theme.mono(9.5, .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.accent)
                    Text("\(note.modelLabel) · after turn \(note.afterTurn)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.text(0.4))
                    if note.severity != "nit", note.severity != "concern" {
                        Text(note.severity.uppercased())
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                    Spacer()
                }
                Text(note.text)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.text(0.85))
                    .lineSpacing(3.5)
                HStack(spacing: 14) {
                    Button("Ask advisor to elaborate") {
                        app.engine?.advisorElaborate(itemId: itemId)
                    }
                    .foregroundStyle(Theme.warning)
                    Button("Ask agent to address") {
                        app.engine?.advisorAddress(itemId: itemId)
                    }
                    .foregroundStyle(Theme.accent)
                    Button("Dismiss") {
                        app.engine?.advisorDismiss(itemId: itemId)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.sans(11, .medium))
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.accent.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accentBorderFaint))
        }
    }
}

// MARK: - Inline approval

struct InlineApprovalCard: View {
    @Environment(AppModel.self) private var app
    let approval: ApprovalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("⚠ APPROVAL")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.warning)
                Text("\(approval.risk == .high ? "destructive" : approval.risk.label.lowercased()) · \(approval.tool)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.text(0.4))
                Spacer()
            }
            .padding(.bottom, 6)
            if !approval.diffLines.isEmpty {
                // Proper review: per-file collapsible sections, add/del tinting,
                // horizontal scroll. The raw blob it came from adds nothing.
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
            Text("reason: \(approval.reason)")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.text(0.5))
                .padding(.bottom, 9)
            ApprovalButtons(height: 32) { verdict in
                app.engine?.resolveApproval(id: approval.id, verdict: verdict)
            } onAlways: { scope in
                app.engine?.resolveApproval(id: approval.id, verdict: .allowAlways, scope: scope)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warning.opacity(0.35)))
    }
}

struct ResolvedInlineApproval: View {
    let approval: ApprovalModel
    var body: some View {
        HStack(spacing: 7) {
            Text(approval.status == .denied ? "✕" : "✓")
            Text(verdictText)
            Text("· \(approval.command ?? approval.tool)")
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
        }
        .font(Theme.mono(11, .medium))
        .foregroundStyle(approval.status == .denied ? Theme.danger : Theme.success)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdictText: String {
        switch approval.status {
        case .denied: "denied"
        case .always: "allowed · rule saved"
        default: "allowed once"
        }
    }
}

// MARK: - Extension dialog (omp `ask`, extension select/confirm/input)

struct DialogCard: View {
    @Environment(AppModel.self) private var app
    let itemId: String
    let dialog: DialogModel
    @State private var inputText = ""

    var body: some View {
        if let answered = dialog.answered {
            HStack(spacing: 7) {
                Text("✓")
                Text("answered: \(answered)")
                Text("· \(dialog.title)")
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.success)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if dialog.cancelled {
            HStack(spacing: 7) {
                Text("✕").foregroundStyle(Theme.textFaint)
                Text("question withdrawn · \(dialog.title)").foregroundStyle(Theme.textFaint)
            }
            .font(Theme.mono(11))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text("? QUESTION")
                        .font(Theme.mono(9.5, .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.accent)
                    Text("omp is waiting on you")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.text(0.4))
                    Spacer()
                }
                .padding(.bottom, 6)
                Text(dialog.title)
                    .font(Theme.sans(12.5, .medium))
                    .foregroundStyle(Theme.text(0.9))
                    .lineSpacing(3)
                    .padding(.bottom, dialog.message == nil ? 9 : 3)
                if let message = dialog.message {
                    Text(message)
                        .font(Theme.sans(11.5))
                        .foregroundStyle(Theme.text(0.6))
                        .lineSpacing(3)
                        .padding(.bottom, 9)
                }
                switch dialog.method {
                case .select:
                    VStack(spacing: 6) {
                        ForEach(dialog.options, id: \.self) { option in
                            Button {
                                app.engine?.answerDialog(itemId: itemId, value: option, confirmed: nil)
                            } label: {
                                Text(option)
                                    .font(Theme.sans(12, .medium))
                                    .foregroundStyle(Theme.text(0.85))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.35)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .confirm:
                    HStack(spacing: 8) {
                        Button {
                            app.engine?.answerDialog(itemId: itemId, value: nil, confirmed: false)
                        } label: {
                            Text("No")
                                .font(Theme.sans(12, .medium))
                                .foregroundStyle(Theme.text(0.7))
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            app.engine?.answerDialog(itemId: itemId, value: nil, confirmed: true)
                        } label: {
                            Text("Yes")
                                .font(Theme.sans(12, .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .background(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(PressableStyle())
                    }
                case .input:
                    HStack(spacing: 8) {
                        TextField(dialog.placeholder ?? "type an answer…", text: $inputText)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.text)
                            .tint(Theme.accent)
                            .onSubmit(sendInput)
                            .padding(.horizontal, 11)
                            .frame(height: 32)
                            .background(Theme.codeBlock)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                        Button(action: sendInput) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        }
                        .buttonStyle(PressableStyle(scale: 0.92))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.35)))
        }
    }

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        app.engine?.answerDialog(itemId: itemId, value: text, confirmed: nil)
    }
}

struct ApprovalButtons: View {
    var height: CGFloat = 30
    var onVerdict: (Verdict) -> Void
    /// When set, "Always" opens the scope picker (contract F) instead of
    /// firing `.allowAlways` directly.
    var onAlways: ((RuleScopeChoice) -> Void)? = nil
    @State private var showScopePicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button { onVerdict(.deny) } label: {
                Text("Deny")
                    .font(Theme.sans(height > 30 ? 12 : 11.5, .medium))
                    .foregroundStyle(Theme.text(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { onVerdict(.allow) } label: {
                Text("Allow once")
                    .font(Theme.sans(height > 30 ? 12 : 11.5, .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(PressableStyle())
            Button {
                if onAlways != nil {
                    showScopePicker = true
                } else {
                    onVerdict(.allowAlways)
                }
            } label: {
                Text("Always")
                    .font(Theme.sans(height > 30 ? 12 : 11.5, .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.5)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog("Allow this every time…", isPresented: $showScopePicker, titleVisibility: .visible) {
            ForEach(RuleScopeChoice.allCases) { choice in
                Button(choice.label) {
                    onAlways?(choice)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scope decides where the always-allow rule applies.")
        }
    }
}

/// Battery: markdown was re-parsed for every visible item on every re-render
/// (which multiplies with streaming deltas). Cache the parse by content.
@MainActor
enum MarkdownCache {
    private static var cache: [String: AttributedString] = [:]

    static func render(_ text: String) -> AttributedString {
        if let hit = cache[text] { return hit }
        let rendered = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        // Streaming produces many short-lived prefixes of the same message;
        // a periodic wholesale drop keeps the cache from growing unbounded.
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        cache[text] = rendered
        return rendered
    }
}
