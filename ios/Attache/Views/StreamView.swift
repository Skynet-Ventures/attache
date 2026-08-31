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
    @State private var attachments: [ComposerAttachment] = []
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showStatsSheet = false
    @State private var sessionAction: SessionActionMode?
    @State private var exporting = false
    @State private var shareItem: ShareURLItem?
    @State private var suppressSlashAutoOpen = false
    // Scrub-back: auto-follow pins the stream to the bottom; scrolling up (or
    // the explicit toggle) disengages it and an unread pill offers to resume.
    @State private var autoFollow = true
    @State private var unreadCount = 0
    @State private var capturedItemCount = 0
    @State private var scrubViewportHeight: CGFloat = 0
    @State private var expandedToolGroups: Set<String> = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            header
            stream
            composer
        }
        .background(Theme.bg)
        .alert("Rename session", isPresented: $showRenameAlert) {
            TextField("session title", text: $renameText)
            Button("Rename") { app.engine?.renameSession(renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showStatsSheet) {
            SessionStatsSheet()
        }
        .sheet(item: $sessionAction) { mode in
            SessionActionSheet(mode: mode) { instructions in
                runSessionAction(mode, instructions: instructions)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
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
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                renameText = app.sessionTitle
                                showRenameAlert = true
                            } label: {
                                Label("Rename session…", systemImage: "pencil")
                            }
                            Button {
                                showStatsSheet = true
                            } label: {
                                Label("Session stats", systemImage: "chart.bar")
                            }
                        }
                    HStack(spacing: 0) {
                        Text("\(app.branchLabel) · turn \(app.turnNo) · ")
                        ElapsedText()
                    }
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button {
                        exportAndShare()
                    } label: {
                        Label("Export transcript…", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button {
                        sessionAction = .handoff
                    } label: {
                        Label("Hand off & continue…", systemImage: "paperplane")
                    }
                    Button {
                        sessionAction = .newSession
                    } label: {
                        Label("Start fresh session from this one…", systemImage: "plus.square.on.square")
                    }
                    Divider()
                    Button {
                        renameText = app.sessionTitle
                        showRenameAlert = true
                    } label: {
                        Label("Rename session…", systemImage: "pencil")
                    }
                    Button {
                        showStatsSheet = true
                    } label: {
                        Label("Session stats", systemImage: "chart.bar")
                    }
                } label: {
                    Text("⋯")
                        .font(Theme.mono(13, .semibold))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(width: 26, height: 26)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
                Button {
                    showStatsSheet = true
                } label: {
                    Text("◫")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(width: 26, height: 26)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
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
            if app.ctxPercent >= 70 {
                HStack(spacing: 8) {
                    BlinkDot(color: Theme.warning, size: 6)
                    Text("context \(Int(app.ctxPercent))% — long sessions risk truncation")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.warning.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        sessionAction = .handoff
                    } label: {
                        Text("handoff ▸")
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    Button {
                        sessionAction = .newSession
                    } label: {
                        Text("new session ▸")
                            .font(Theme.mono(9.5, .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent.opacity(0.5)))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.bottom, 9)
            }
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    // MARK: Stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(StreamGrouping.renderUnits(from: app.items)) { unit in
                            switch unit {
                            case .item(let item):
                                ChatItemView(item: item)
                                    .id(item.id)
                            case .toolRun(let group):
                                ToolRunCard(
                                    group: group,
                                    expanded: expandedToolGroups.contains(group.id)
                                ) {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if expandedToolGroups.contains(group.id) {
                                            expandedToolGroups.remove(group.id)
                                        } else {
                                            expandedToolGroups.insert(group.id)
                                        }
                                    }
                                }
                                .id(group.id)
                            }
                        }
                        if app.typing {
                            TypingIndicator()
                        }
                        // Clearance so the floating follow pill sits in empty
                        // space (not against a card border) when pinned.
                        Color.clear.frame(height: 40).id("stream-bottom")
                    } header: {
                        if let goal = app.goal, goal.active {
                            GoalBanner(goal: goal)
                                .padding(.bottom, 2)
                        }
                    }
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.vertical, 12)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: StreamContentGeomKey.self,
                            value: StreamContentGeom(
                                contentHeight: geo.size.height,
                                topOffset: geo.frame(in: .named("stream-scroll")).minY
                            )
                        )
                    }
                )
            }
            .coordinateSpace(name: "stream-scroll")
            .defaultScrollAnchor(.bottom)
            // Reading room: drag pushes the keyboard away interactively, and
            // a tap on any non-interactive part of the stream drops it too.
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { composerFocused = false }
            // Scrubbing up (finger drags downward) disengages auto-follow.
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if autoFollow, value.translation.height > 0 {
                            disengageFollow()
                        }
                    }
            )
            .background(
                GeometryReader { vp in
                    Color.clear.preference(key: StreamViewportKey.self, value: vp.size.height)
                }
            )
            .onPreferenceChange(StreamContentGeomKey.self) { geom in
                let distance = max(0, scrubViewportHeight - (geom.contentHeight + geom.topOffset))
                // Reaching the bottom re-engages auto-follow.
                if !autoFollow, distance < 80 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("stream-bottom", anchor: .bottom)
                    }
                    resumeFollow()
                }
            }
            .onPreferenceChange(StreamViewportKey.self) { height in
                scrubViewportHeight = height
            }
            .onChange(of: app.items.count) {
                if autoFollow {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("stream-bottom", anchor: .bottom)
                    }
                } else {
                    unreadCount = max(unreadCount, app.items.count - capturedItemCount)
                }
            }
            .onChange(of: app.typing) {
                if autoFollow {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("stream-bottom", anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                scrubNotice(proxy: proxy)
                    // Floats over scrolling content — the shadow makes an
                    // overlap read as layered instead of touching.
                    .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                    // Breathing room off the composer hairline / screen edge.
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    /// The follow toggle (pinned) or the "N new ↓" unread resume pill.
    @ViewBuilder
    private func scrubNotice(proxy: ScrollViewProxy) -> some View {
        if autoFollow {
            // Same footprint as the "N new ↓" pill so the state toggle doesn't
            // shrink into something that reads as a rendering glitch.
            Button {
                disengageFollow()
            } label: {
                HStack(spacing: 5) {
                    Text("following")
                        .font(Theme.mono(10, .medium))
                    Text("⌄")
                        .font(Theme.mono(11, .semibold))
                }
                .foregroundStyle(Theme.text(0.55))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.chip))
                .overlay(Capsule().stroke(Theme.hairlineStrong))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("stream-bottom", anchor: .bottom)
                }
                resumeFollow()
            } label: {
                HStack(spacing: 5) {
                    if unreadCount > 0 {
                        Text("\(unreadCount) new")
                            .font(Theme.mono(10, .semibold))
                    }
                    Text("↓")
                        .font(Theme.mono(11, .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
    }

    private func disengageFollow() {
        guard autoFollow else { return }
        autoFollow = false
        capturedItemCount = app.items.count
        unreadCount = 0
    }

    private func resumeFollow() {
        guard !autoFollow else { return }
        autoFollow = true
        unreadCount = 0
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if showSlashSheet { SlashPalette(query: slashQuery, onPick: pickSlash) }
            if showRoleSheet { RolePickerSheet(onPick: pickRole) }
            if showModelSheet { ModelPickerSheet(onPick: pickModel) }
            if showBranchSheet { BranchSheet(onPick: pickBranch) }
            VStack(spacing: 9) {
                if !attachments.isEmpty {
                    attachmentStrip
                }
                HStack(spacing: 8) {
                    // The ▾ promises a menu — deliver one instead of tap-cycling.
                    Menu {
                        ForEach(ComposerMode.allCases, id: \.self) { mode in
                            Button {
                                app.composerMode = mode
                            } label: {
                                if mode == app.composerMode {
                                    Label(modeMenuLabel(mode), systemImage: "checkmark")
                                } else {
                                    Text(modeMenuLabel(mode))
                                }
                            }
                        }
                    } label: {
                        Text("\(app.composerMode.rawValue) ▾")
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .fixedSize()
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
                            .lineLimit(1)
                            .fixedSize()   // never wrap the ▾ under the text
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
                        app.engine?.setFastMode(!app.fastModeActive)
                    } label: {
                        Text("⚡ fast")
                            .font(Theme.mono(10, .medium))
                            .foregroundStyle(app.fastModeActive ? Theme.warning : Theme.text(0.6))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(app.fastModeActive ? Theme.warning.opacity(0.5) : Theme.hairlineStrong))
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
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Photo library", systemImage: "photo")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Files", systemImage: "doc")
                        }
                    } label: {
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
                    .photosPicker(isPresented: $showPhotosPicker, selection: $pickedPhotos, maxSelectionCount: 4, matching: .images)
                    .onChange(of: pickedPhotos) { loadPickedPhotos() }
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.item],
                        allowsMultipleSelection: true
                    ) { result in
                        loadPickedFiles(result)
                    }
                    HStack(spacing: 8) {
                        TextField("Message omp…", text: $draft, axis: .vertical)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.text)
                            .tint(Theme.accent)
                            .lineLimit(1...4)
                            .focused($composerFocused)
                            .onSubmit(sendDraft)
                            // Typing "/" opens the searchable palette; removing
                            // the leading slash closes it.
                            .onChange(of: draft) { old, new in
                                if suppressSlashAutoOpen {
                                    suppressSlashAutoOpen = false
                                } else if new.hasPrefix("/"), !old.hasPrefix("/") {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSlashSheet = true
                                        showRoleSheet = false
                                        showModelSheet = false
                                        showBranchSheet = false
                                    }
                                } else if !new.hasPrefix("/") {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showSlashSheet = false
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 13)
                    .frame(minHeight: 38)
                    .background(Theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairlineStrong))
                    // Send on tap; long-press opens the slash palette instead.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent))
                        .contentShape(Circle())
                        .onTapGesture { sendDraft() }
                        .onLongPressGesture(minimumDuration: 0.45) {
                            openSlashPalette()
                        }
                }
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(Theme.composer)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .top)
    }

    private func modeMenuLabel(_ mode: ComposerMode) -> String {
        switch mode {
        case .chat: "Chat — normal turn"
        case .plan: "Plan — read-only draft"
        case .goal: "Goal — self-driving loop"
        case .loop: "Loop — resubmit N times"
        }
    }

    private var shortModelLabel: String {
        let label = app.modelLabel.isEmpty ? "model" : app.modelLabel
        return String(label.prefix(14))
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if attachment.kind == .image, let ui = UIImage(data: attachment.data) {
                            Image(uiImage: ui)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                        } else {
                            VStack(spacing: 3) {
                                Image(systemName: "doc")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.accent)
                                Text(attachment.name)
                                    .font(Theme.mono(7.5))
                                    .foregroundStyle(Theme.text(0.6))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .frame(width: 74, height: 52)
                            .background(Theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                        }
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
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
                attachments.append(.image(jpeg))
            }
        }
    }

    private func loadPickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard data.count <= 25 * 1024 * 1024 else {
                app.append(.notice("\(url.lastPathComponent) skipped — over the 25MB upload cap"))
                continue
            }
            attachments.append(.file(name: url.lastPathComponent, data: data))
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
        app.engine?.send(text, mode: app.composerMode, role: app.composerRole, attachments: images)
    }

    private func pickModel(_ model: String) {
        app.engine?.setModel(model)
        showModelSheet = false
    }

    private func pickSlash(_ cmd: String) {
        draft = cmd + " "
        showSlashSheet = false
        suppressSlashAutoOpen = true
        composerFocused = true
    }

    private func openSlashPalette() {
        withAnimation(.easeOut(duration: 0.15)) {
            showSlashSheet.toggle()
            showRoleSheet = false
            showModelSheet = false
            showBranchSheet = false
        }
    }

    /// Palette search is the composer draft itself — typing filters live.
    private var slashQuery: String {
        draft.hasPrefix("/") ? draft : ""
    }

    private func pickRole(_ role: String) {
        app.engine?.pickRole(role)
        showRoleSheet = false
    }

    private func pickBranch(_ point: BranchPoint) {
        showBranchSheet = false
        app.engine?.branch(entryId: point.id, preview: point.preview)
    }

    // MARK: Session actions (handoff / new-session-from-parent / export)

    private func runSessionAction(_ mode: SessionActionMode, instructions: String?) {
        guard let engine = app.engine else { return }
        switch mode {
        case .handoff:
            // Hand off, then land in a fresh descended session (the contract
            // flow: attach to the resulting session).
            guard let parent = app.activeSummary else {
                Task { _ = await engine.handoff(instructions: instructions) }
                return
            }
            Task {
                _ = await engine.handoff(instructions: instructions)
                engine.newSession(parent: parent, instructions: nil)
            }
        case .newSession:
            guard let parent = app.activeSummary else { return }
            engine.newSession(parent: parent, instructions: instructions)
        }
    }

    private func exportAndShare() {
        guard let engine = app.engine else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let base64 = try await engine.exportTranscript()
                guard let data = Data(base64Encoded: base64) else {
                    app.append(.notice("export decode failed"))
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("transcript-\(Int(Date().timeIntervalSince1970)).html")
                try data.write(to: url, options: .atomic)
                shareItem = ShareURLItem(url: url)
            } catch let error as BridgeError where error.code == "too_large" {
                // Contract D: the bridge caps the payload at 20MB; tell the
                // user gracefully instead of dumping an error sheet.
                app.append(.notice("transcript too large to export from this device (20MB cap)"))
            } catch {
                app.append(.notice("export failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }
}

/// Which confirmation sheet the session menu opens (contracts A & B).
enum SessionActionMode: String, Identifiable {
    case handoff
    case newSession
    var id: String { rawValue }
}

struct ShareURLItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Confirmation sheet for handoff / new-session-from-parent. Offers an
/// optional instructions field; confirm routes to the engine.
struct SessionActionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: SessionActionMode
    var onConfirm: (String?) -> Void
    @State private var instructions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(mode == .handoff ? "✉" : "⑂")
                    .font(Theme.mono(14, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(mode == .handoff ? "Hand off this session" : "Start from this session")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(width: 30, height: 30)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.vertical, 10)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                Text(mode == .handoff
                    ? "omp writes a handoff document and we start a fresh session seeded with it. The original session stays untouched for review."
                    : "A fresh session is spawned from this session's file — context carries over, history does not mutate.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.text(0.6))
                    .lineSpacing(3)
                TextField(mode == .handoff ? "optional instructions for the next session…" : "optional instructions for the fresh session…", text: $instructions, axis: .vertical)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.text)
                    .tint(Theme.accent)
                    .lineLimit(2...4)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Theme.codeBlock)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                HStack(spacing: 8) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(Theme.sans(12, .medium))
                            .foregroundStyle(Theme.text(0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.15)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        dismiss()
                        onConfirm(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instructions)
                    } label: {
                        Text(mode == .handoff ? "Hand off & continue" : "Start new session")
                            .font(Theme.sans(12.5, .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                }
            }
            .padding(Theme.streamGutter)
            .padding(.top, 10)
        }
        .presentationDetents([.height(300)])
        .presentationBackground(Theme.sheet)
    }
}

/// UIActivityViewController share sheet for the exported transcript.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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

/// Searchable slash palette fed by omp's advertised commands (bridge
/// `commands` event). Filters live against the composer draft; selecting a
/// row inserts the command text. Falls back to built-ins without a bridge.
struct SlashPalette: View {
    @Environment(AppModel.self) private var app
    var query: String
    var onPick: (String) -> Void

    private var commands: [SlashCommand] {
        let advertised = app.availableCommands
        return advertised.isEmpty ? Self.builtinFallback : advertised
    }

    private static let builtinFallback: [SlashCommand] = [
        SlashCommand(name: "/plan", source: "builtin", summary: "read-only drafting pass, structured handoff", hint: "<objective>"),
        SlashCommand(name: "/goal", source: "builtin", summary: "pin an objective, self-driving loop until proven done", hint: "<objective>"),
        SlashCommand(name: "/loop", source: "builtin", summary: "resubmit the same prompt N times", hint: "<n> <prompt>"),
        SlashCommand(name: "/compact", source: "builtin", summary: "snapcompact the context now"),
        SlashCommand(name: "/agents", source: "builtin", summary: "open the agent hub"),
        SlashCommand(name: "/resume", source: "builtin", summary: "session picker"),
        SlashCommand(name: "/new", source: "builtin", summary: "new saved session"),
    ]

    private var needle: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let dropped = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return dropped.lowercased()
    }

    private var rows: [(name: String, summary: String?, hint: String?, indent: Bool)] {
        let all: [(name: String, summary: String?, hint: String?, indent: Bool)] = commands.flatMap { cmd in
            [(name: cmd.name, summary: cmd.summary, hint: cmd.hint, indent: false)]
                + cmd.subcommands.map { (name: $0.name, summary: $0.summary, hint: $0.hint, indent: true) }
        }
        guard !needle.isEmpty else { return all }
        return all.filter { row in
            if row.name.lowercased().contains(needle) { return true }
            if let summary = row.summary, summary.lowercased().contains(needle) { return true }
            if let hint = row.hint, hint.lowercased().contains(needle) { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SEARCH — TYPE TO FILTER")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.text(0.4))
                Spacer()
                Text("\(rows.count) shown")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 13)
            .padding(.top, 9)
            .padding(.bottom, 5)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("no command matches \"\(needle)\"")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                    }
                    ForEach(rows, id: \.name) { row in
                        Button { onPick(row.name) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.name)
                                    .font(Theme.mono(11.5, .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: row.indent ? 98 : 74, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let summary = row.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(Theme.sans(11))
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    if let hint = row.hint, !hint.isEmpty {
                                        Text(hint)
                                            .font(Theme.mono(9))
                                            .foregroundStyle(Theme.text(0.3))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.name != rows.last?.name {
                            Divider().overlay(Theme.hairlineFaint)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
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

// MARK: - Session stats

/// Grouped read-only view of the bridge's `get_session_stats` passthrough —
/// omp's raw stats (tokens, cost, cache) rendered verbatim in key/value rows.
struct SessionStatsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [SessionStatRow] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(width: 30, height: 30)
                        .background(Theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairlineStrong))
                }
                .buttonStyle(.plain)
                Text("Session stats")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.vertical, 10)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)

            if loading {
                Spacer()
                ProgressView().controlSize(.small).tint(Theme.accent)
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text("no stats reported for this session")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("QUEUE MODES — ADVANCED")
                            .font(Theme.mono(9.5, .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.text(0.4))
                            .padding(.horizontal, 13)
                            .padding(.top, 12)
                            .padding(.bottom, 5)
                        VStack(spacing: 0) {
                            queueModeRow("Steering", selection: Binding(
                                get: { app.steeringMode.rawValue },
                                set: { newValue in
                                    if let m = QueueSteeringMode(rawValue: newValue) {
                                        applyQueueModes(steering: m, followUp: app.followUpMode, interrupt: app.interruptMode)
                                    }
                                }
                            ), options: [QueueSteeringMode.all.rawValue, QueueSteeringMode.oneAtATime.rawValue])
                            Divider().overlay(Theme.hairlineFaint)
                            queueModeRow("Follow-ups", selection: Binding(
                                get: { app.followUpMode.rawValue },
                                set: { newValue in
                                    if let m = QueueFollowUpMode(rawValue: newValue) {
                                        applyQueueModes(steering: app.steeringMode, followUp: m, interrupt: app.interruptMode)
                                    }
                                }
                            ), options: [QueueFollowUpMode.all.rawValue, QueueFollowUpMode.oneAtATime.rawValue])
                            Divider().overlay(Theme.hairlineFaint)
                            queueModeRow("Interrupt", selection: Binding(
                                get: { app.interruptMode.rawValue },
                                set: { newValue in
                                    if let m = QueueInterruptMode(rawValue: newValue) {
                                        applyQueueModes(steering: app.steeringMode, followUp: app.followUpMode, interrupt: m)
                                    }
                                }
                            ), options: [QueueInterruptMode.immediate.rawValue, QueueInterruptMode.wait.rawValue])
                        }
                        .background(Theme.raisedAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
                        .padding(.bottom, 14)
                        Text("FROM OMP — READ-ONLY")
                            .font(Theme.mono(9.5, .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.text(0.4))
                            .padding(.horizontal, 13)
                            .padding(.top, 12)
                            .padding(.bottom, 5)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.key)
                                    .font(Theme.mono(10.5, .medium))
                                    .foregroundStyle(Theme.text(0.7))
                                Spacer()
                                Text(row.value)
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(Theme.text(0.55))
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            if idx < rows.count - 1 {
                                Divider().overlay(Theme.hairlineFaint)
                            }
                        }
                    }
                    .background(Theme.raisedAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
                    .padding(.horizontal, Theme.streamGutter)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Theme.bg)
        .task {
            rows = await app.engine?.fetchSessionStats() ?? []
            loading = false
        }
    }

    /// One queue-mode picker row: label + two-option segmented control.
    private func queueModeRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.text)
            Spacer()
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        Text(optionLabel(option))
                            .font(Theme.mono(9.5, selection.wrappedValue == option ? .semibold : .medium))
                            .foregroundStyle(selection.wrappedValue == option ? .black : Theme.text(0.45))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(selection.wrappedValue == option ? Theme.accent : .clear)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    private func optionLabel(_ raw: String) -> String {
        switch raw {
        case "one-at-a-time": "one at a time"
        case "immediate": "immediate"
        case "wait": "wait for turn"
        default: raw
        }
    }

    /// Persist a queue-mode change to the bridge (contract C) and mirror the
    /// echoed final modes from session_state.
    private func applyQueueModes(
        steering: QueueSteeringMode, followUp: QueueFollowUpMode, interrupt: QueueInterruptMode
    ) {
        app.engine?.setQueueModes(steeringMode: steering, followUpMode: followUp, interruptMode: interrupt)
    }
}

// MARK: - Scrub geometry plumbing

/// Scroll metrics captured from the stream content for the follow/scrub
/// behavior. Tracks distance-from-bottom without iOS 18-only APIs.
private struct StreamContentGeom: Equatable {
    var contentHeight: CGFloat = 0
    var topOffset: CGFloat = 0
}

private struct StreamContentGeomKey: PreferenceKey {
    static var defaultValue: StreamContentGeom = StreamContentGeom()
    static func reduce(value: inout StreamContentGeom, nextValue: () -> StreamContentGeom) {
        value = nextValue()
    }
}

private struct StreamViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Battery: elapsed time derives itself on a 1s TimelineView schedule inside
/// this leaf — nothing mutates AppModel per second, so the rest of the view
/// tree never re-renders for the clock.
struct ElapsedText: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(at: context.date))
        }
    }

    private func label(at now: Date) -> String {
        let seconds: Int
        if let start = app.turnStartedAt {
            seconds = max(0, Int(now.timeIntervalSince(start))) + app.elapsedSec
        } else {
            seconds = app.elapsedSec
        }
        return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
    }
}
