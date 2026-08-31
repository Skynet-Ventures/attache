import PhotosUI
import SwiftUI

struct StreamView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var showRoleSheet = false
    @State private var showModelSheet = false
    @State private var showSlashSheet = false
    @State private var showBranchSheet = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var attachments: [AttachedImage] = []
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
            if showModelSheet { ModelPickerSheet(onPick: pickModel) }
            if showBranchSheet { BranchSheet(onPick: pickBranch) }
            VStack(spacing: 9) {
                if !attachments.isEmpty {
                    attachmentStrip
                }
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
                        withAnimation { showRoleSheet.toggle(); showModelSheet = false; showSlashSheet = false; showBranchSheet = false }
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
                        withAnimation { showModelSheet.toggle(); showRoleSheet = false; showSlashSheet = false; showBranchSheet = false }
                    } label: {
                        Text("\(shortModelLabel) ▾")
                            .font(Theme.mono(10, .medium))
                            .foregroundStyle(Theme.text(0.6))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairlineStrong))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Button {
                        withAnimation { showSlashSheet.toggle(); showRoleSheet = false; showModelSheet = false; showBranchSheet = false }
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
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 4, matching: .images) {
                        Text("+")
                            .font(Theme.sans(19, .light))
                            .foregroundStyle(attachments.isEmpty ? Theme.text(0.6) : Theme.accent)
                            .padding(.bottom, 2)
                            .frame(width: 32, height: 32)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(attachments.isEmpty ? Theme.hairlineStrong : Theme.accentBorder))
                    }
                    .buttonStyle(.plain)
                    .onChange(of: pickedPhotos) { loadPickedPhotos() }
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

    private var shortModelLabel: String {
        let label = app.modelLabel.isEmpty ? "model" : app.modelLabel
        return String(label.prefix(14))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { image in
                    ZStack(alignment: .topTrailing) {
                        if let ui = UIImage(data: image.jpegData) {
                            Image(uiImage: ui)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                        }
                        Button {
                            attachments.removeAll { $0.id == image.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text, Theme.codeBlock)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(height: 56)
    }

    private func loadPickedPhotos() {
        let items = pickedPhotos
        pickedPhotos = []
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                // Downscale for the model: long edge ≤ 1568px, JPEG.
                let maxEdge: CGFloat = 1568
                let scale = min(1, maxEdge / max(image.size.width, image.size.height))
                let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: target)
                let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
                guard let jpeg = scaled.jpegData(compressionQuality: 0.7) else { continue }
                attachments.append(AttachedImage(jpegData: jpeg))
            }
        }
    }

    private func sendDraft() {
        let text = draft
        let images = attachments
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !images.isEmpty else { return }
        draft = ""
        attachments = []
        showSlashSheet = false
        showRoleSheet = false
        showModelSheet = false
        app.engine?.send(text, mode: app.composerMode, role: app.composerRole, images: images)
    }

    private func pickModel(_ model: String) {
        app.engine?.setModel(model)
        showModelSheet = false
    }

    private func pickSlash(_ cmd: String) {
        draft = cmd + " "
        showSlashSheet = false
        composerFocused = true
    }

    private func pickRole(_ role: String) {
        app.engine?.pickRole(role)
        showRoleSheet = false
    }

    private func pickBranch(_ point: BranchPoint) {
        showBranchSheet = false
        app.engine?.branch(entryId: point.id, preview: point.preview)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SWITCH ROLE — SETS MODEL + THINKING")
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
        }
        .frame(maxHeight: 360)
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

/// Dedicated model picker — distinct from the @role picker: switches the
/// session's active model directly via set_model.
struct ModelPickerSheet: View {
    @Environment(AppModel.self) private var app
    var onPick: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("SWITCH SESSION MODEL")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.text(0.4))
                    .padding(.horizontal, 13)
                    .padding(.top, 9)
                    .padding(.bottom, 5)
                if app.enabledModels.isEmpty {
                    Text("no models reported by the bridge")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                }
                ForEach(app.enabledModels, id: \.self) { model in
                    let short = model.split(separator: "/").last.map(String.init) ?? model
                    let isCurrent = short == app.modelLabel
                    Button { onPick(model) } label: {
                        HStack(spacing: 8) {
                            Text(short)
                                .font(Theme.mono(11, isCurrent ? .semibold : .regular))
                                .foregroundStyle(isCurrent ? Theme.accent : Theme.text(0.85))
                                .lineLimit(1)
                            if isCurrent {
                                Text("current")
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.accent.opacity(0.7))
                            }
                            Spacer()
                            Text(model.split(separator: "/").first.map(String.init) ?? "")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.text(0.35))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .frame(maxHeight: 320)
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: -10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct BranchSheet: View {
    @Environment(AppModel.self) private var app
    var onPick: (BranchPoint) -> Void
    @State private var points: [BranchPoint] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("⑂ BRANCH THIS SESSION — HISTORY STAYS INTACT")
                .font(Theme.mono(9.5, .semibold))
                .tracking(1)
                .foregroundStyle(Theme.text(0.4))
                .padding(.horizontal, 13)
                .padding(.top, 9)
                .padding(.bottom, 5)
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                    Text("reading session entries…")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            } else if points.isEmpty {
                Text("no branchable turns yet")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
            }
            ForEach(Array(points.prefix(5).enumerated()), id: \.element.id) { idx, point in
                Button { onPick(point) } label: {
                    HStack(spacing: 8) {
                        Text("⑂")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                        Text("\(point.preview)\(idx == 0 ? " — latest" : "")")
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Theme.hairlineFaint)
            }
        }
        .task {
            points = await app.engine?.branchPoints() ?? []
            loading = false
        }
        .background(Theme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.6), radius: 20, y: -10)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}
