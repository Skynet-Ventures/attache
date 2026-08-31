import SwiftUI

struct StreamView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var showRoleSheet = false
    @State private var showSlashSheet = false
    @State private var showBranchSheet = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            header
            stream
            composer
        }
        .background(Theme.bg)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BackChevron { dismiss() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.sessionTitle)
                        .font(Theme.sans(15, .semibold))
                        .foregroundStyle(Theme.text)
                        .kerning(-0.15)
                        .lineLimit(1)
                    Text("\(app.branchLabel) · turn \(app.turnNo) · \(app.elapsedLabel)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showBranchSheet.toggle()
                    showRoleSheet = false
                    showSlashSheet = false
                } label: {
                    Text("⑂")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(width: 26, height: 26)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.bottom, 8)
            HStack(spacing: 8) {
                ContextBar(percent: app.ctxPercent)
                Text("\(app.ctxLabel) · \(String(format: "$%.2f", app.costUsd)) · \(app.compactNote)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.bottom, 9)
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    // MARK: Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(app.items) { item in
                            ChatItemView(item: item)
                                .id(item.id)
                        }
                        if app.typing {
                            TypingIndicator()
                        }
                        Color.clear.frame(height: 1).id("stream-bottom")
                    } header: {
                        if let goal = app.goal, goal.active {
                            GoalBanner(goal: goal)
                                .padding(.bottom, 2)
                        }
                    }
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: app.items.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("stream-bottom", anchor: .bottom)
                }
            }
            .onChange(of: app.typing) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("stream-bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if showSlashSheet { SlashPalette(onPick: pickSlash) }
            if showRoleSheet { RolePickerSheet(onPick: pickRole) }
            if showBranchSheet { BranchSheet(onPick: pickBranch) }
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            app.composerMode = app.composerMode.next
                        }
                    } label: {
                        Text("\(app.composerMode.rawValue) ▾")
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Theme.accent.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accentBorder))
                    }
                    .buttonStyle(PressableStyle(scale: 0.94))
                    Button {
                        withAnimation { showRoleSheet.toggle(); showSlashSheet = false; showBranchSheet = false }
                    } label: {
                        Text("@\(app.composerRole) ▾")
                            .font(Theme.mono(10, .medium))
                            .foregroundStyle(Theme.text(0.6))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairlineStrong))
                    }
                    .buttonStyle(.plain)
                    Button {
                        withAnimation { showSlashSheet.toggle(); showRoleSheet = false; showBranchSheet = false }
                    } label: {
                        Text("/")
                            .font(Theme.mono(10, .medium))
                            .foregroundStyle(Theme.text(0.6))
                            .frame(width: 24, height: 24)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairlineStrong))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if app.turnActive && !app.typing {
                        Button {
                            app.engine?.stopTurn()
                        } label: {
                            Text("■ stop turn")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 9) {
                    Button {} label: {
                        Text("+")
                            .font(Theme.sans(19, .light))
                            .foregroundStyle(Theme.text(0.6))
                            .padding(.bottom, 2)
                            .frame(width: 32, height: 32)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        TextField("Message omp…", text: $draft, axis: .vertical)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.text)
                            .tint(Theme.accent)
                            .lineLimit(1...4)
                            .focused($composerFocused)
                            .onSubmit(sendDraft)
                        Image(systemName: "mic")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text(0.5))
                    }
                    .padding(.horizontal, 13)
                    .frame(minHeight: 38)
                    .background(Theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairlineStrong))
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.accent))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                }
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(Theme.composer)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .top)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        showSlashSheet = false
        showRoleSheet = false
        app.engine?.send(text, mode: app.composerMode, role: app.composerRole)
    }

    private func pickSlash(_ cmd: String) {
        draft = cmd + " "
        showSlashSheet = false
        composerFocused = true
    }

    private func pickRole(_ role: String) {
        app.composerRole = role
        showRoleSheet = false
    }

    private func pickBranch(_ item: ChatItem, label: String) {
        showBranchSheet = false
        app.engine?.branch(fromEntry: item)
    }
}

// MARK: - Goal banner

struct GoalBanner: View {
    @Environment(AppModel.self) private var app
    let goal: GoalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text("◎ GOAL")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.accent)
                Text("turn \(goal.turns) / budget \(goal.budget)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("pause") { app.engine?.goalPause() }
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(Theme.text(0.6))
                    .buttonStyle(.plain)
                Button("drop") { app.engine?.goalDrop() }
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(Theme.danger)
                    .buttonStyle(.plain)
            }
            Text(goal.objective)
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.text(0.85))
                .lineSpacing(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color(hex: 0x180D07).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accentBorder))
    }
}

// MARK: - Composer sheets

struct SlashPalette: View {
    var onPick: (String) -> Void
    private let items: [(String, String)] = [
        ("/plan", "read-only drafting pass, structured handoff"),
        ("/goal", "pin an objective, self-driving loop until proven done"),
        ("/loop", "resubmit the same prompt N times"),
        ("/compact", "snapcompact the context now"),
        ("/agents", "open the agent hub"),
        ("/resume", "session picker"),
        ("/new", "new saved session"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.0) { cmd, desc in
                Button { onPick(cmd) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(cmd)
                            .font(Theme.mono(11.5, .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 74, alignment: .leading)
                        Text(desc)
                            .font(Theme.sans(11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if cmd != items.last?.0 {
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: -10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct RolePickerSheet: View {
    @Environment(AppModel.self) private var app
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SEND NEXT MESSAGE AS ROLE")
                .font(Theme.mono(9.5, .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text(0.4))
                .padding(.horizontal, 13)
                .padding(.top, 9)
                .padding(.bottom, 5)
            ForEach(app.roles) { role in
                Button { onPick(role.name) } label: {
                    HStack(spacing: 10) {
                        Text(role.name)
                            .font(Theme.mono(11, .semibold))
                            .foregroundStyle(roleColor(role.name))
                            .frame(width: 66, alignment: .leading)
                        Text(role.model)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.text(0.6))
                            .lineLimit(1)
                        Spacer()
                        Text(role.thinking.rawValue)
                            .font(Theme.mono(9, .medium))
                            .foregroundStyle(Theme.text(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.16)))
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairlineFaint)
            }
        }
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: -10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func roleColor(_ name: String) -> Color {
        if name == "default" { return Theme.accent }
        if name == "advisor" { return Theme.warning }
        return Theme.text(0.6)
    }
}

struct BranchSheet: View {
    @Environment(AppModel.self) private var app
    var onPick: (ChatItem, String) -> Void

    private var candidates: [(ChatItem, String)] {
        // Offer the last few turn boundaries, newest first.
        var seen = Set<Int>()
        var out: [(ChatItem, String)] = []
        for item in app.items.reversed() {
            guard item.turn > 0, !seen.contains(item.turn) else { continue }
            seen.insert(item.turn)
            let suffix = out.isEmpty ? " — now" : ""
            out.append((item, "from turn \(item.turn)\(suffix)"))
            if out.count == 3 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("⑂ BRANCH THIS SESSION — HISTORY STAYS INTACT")
                .font(Theme.mono(9.5, .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text(0.4))
                .padding(.horizontal, 13)
                .padding(.top, 9)
                .padding(.bottom, 5)
            ForEach(candidates, id: \.0.id) { item, label in
                Button { onPick(item, label) } label: {
                    Text(label)
                        .font(Theme.mono(11.5, .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairlineFaint)
            }
        }
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: -10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}
