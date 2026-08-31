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
        }
    }

    private func markdownish(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
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
                if let add = tool.addCount, let del = tool.delCount {
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
            if let command = approval.command {
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
            if !approval.diffLines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(approval.diffLines) { DiffLineView(line: $0, fontSize: 10) }
                }
                .padding(.vertical, 6)
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

struct ApprovalButtons: View {
    var height: CGFloat = 30
    var onVerdict: (Verdict) -> Void

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
            Button { onVerdict(.allowAlways) } label: {
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
    }
}
