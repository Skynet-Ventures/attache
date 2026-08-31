import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showPlusMenu = false
    @State private var showNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    quickChips
                    searchField
                    pinnedSection
                    projectLists
                }
                .padding(.bottom, 30)
            }
        }
        .background(Theme.bg)
        .confirmationDialog("", isPresented: $showPlusMenu) {
            Button("New project") { showNewProject = true }
            Button("Resume or start a session") { app.path.append(.resume) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet()
                .presentationDetents([.height(260)])
                .presentationBackground(Theme.raisedAlt)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("å")
                .font(Theme.mono(15, .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
            VStack(alignment: .leading, spacing: 1) {
                Text("Attaché")
                    .font(Theme.sans(17, .bold))
                    .foregroundStyle(Theme.text)
                    .kerning(-0.3)
                HStack(spacing: 4) {
                    Text("●").font(Theme.mono(10, .medium)).foregroundStyle(machineDotColor)
                    Text(machineLabel).font(Theme.mono(10, .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            Button {
                showPlusMenu = true
            } label: {
                Text("+")
                    .font(Theme.sans(22))
                    .foregroundStyle(.black)
                    .padding(.bottom, 2)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(PressableStyle(scale: 0.92))
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var machineDotColor: Color {
        switch app.machine.link {
        case .online, .demo: Theme.success
        case .connecting: Theme.warning
        case .offline: Theme.danger
        }
    }

    private var machineLabel: String {
        switch app.machine.link {
        case .online(let ms): "\(app.machine.name) · tailscale · \(ms)ms"
        case .demo: "\(app.machine.name) · demo data"
        case .connecting: "\(app.machine.name) · connecting…"
        case .offline: app.machine.name == "no machine" ? "not paired" : "\(app.machine.name) · unreachable — retrying"
        }
    }

    // MARK: Quick chips

    private var quickChips: some View {
        HStack(spacing: 7) {
            Button { app.path.append(.agents) } label: {
                HStack(spacing: 6) {
                    BlinkDot(color: Theme.accent, size: 6)
                    Text("agents \(app.liveAgentCount)")
                        .font(Theme.mono(10.5, .medium))
                        .foregroundStyle(Theme.text(0.75))
                }
                .chipBackground(border: Theme.hairlineStrong)
            }
            Button { app.path.append(.approvals) } label: {
                Text("approvals \(app.pendingApprovalCount)")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.warning)
                    .chipBackground(border: Theme.warning.opacity(0.35))
            }
            Button { app.path.append(.machines) } label: {
                Text("machines")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.text(0.6))
                    .chipBackground(border: Theme.hairlineStrong)
            }
            Button { app.path.append(.settings) } label: {
                Text("roles")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.text(0.6))
                    .chipBackground(border: Theme.hairlineStrong)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        Button { app.path.append(.resume) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                Text("Search sessions, prompts, files…")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.searchField)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairlineFaint))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 14)
    }

    // MARK: Pinned cards

    private var runningSession: SessionSummary? {
        app.projects.flatMap(\.sessions).first { $0.live && ($0.status == .running || $0.id == app.sessionId) }
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runningSession != nil || app.plan != nil {
                SectionHeader(title: "Pinned")
                    .padding(.horizontal, Theme.gutter)
            }
            if let session = runningSession {
                runningCard(session)
                    .padding(.horizontal, Theme.gutter)
            }
            if app.plan != nil {
                planCard
                    .padding(.horizontal, Theme.gutter)
            }
        }
        .padding(.bottom, 16)
    }

    private var homeStatusLine: String {
        if app.pendingApprovalCount > 0,
           let a = app.approvals.first(where: { $0.status == .pending && $0.sessionId == app.sessionId }) {
            return "waiting on approval · \(a.command ?? a.tool)"
        }
        return "editing internal — turn \(app.turnNo)"
    }

    private func runningCard(_ session: SessionSummary) -> some View {
        Button {
            app.path.append(.stream)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    BlinkDot(color: Theme.accent, size: 7, glow: true)
                    Text(session.title)
                        .font(Theme.sans(14.5, .semibold))
                        .foregroundStyle(Theme.text)
                        .kerning(-0.15)
                        .lineLimit(1)
                    Spacer()
                    Text("RUNNING")
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.bottom, 6)
                Text(homeStatusLine)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.bottom, 10)
                ContextBar(percent: app.ctxPercent)
                    .padding(.bottom, 8)
                HStack(spacing: 10) {
                    Text(session.project)
                    Text("ctx \(Int(app.ctxPercent))%")
                    Text(String(format: "$%.2f", app.costUsd))
                    if app.liveAgentCount > 0 {
                        Text("\(app.liveAgentCount) agents live").foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text(app.modelLabel)
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.pinnedRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.pinnedRadius).stroke(Theme.accent.opacity(0.35)))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    private var planCard: some View {
        let plan = app.plan!
        let (badge, badgeColor, dot, line, border): (String, Color, Color, String, Color) = {
            switch plan.state {
            case .executing(let step):
                return ("EXECUTING", Theme.accent, Theme.accent,
                        "executing plan · step \(step)/\(plan.steps.count) · \(plan.steps[safe: step - 1]?.title.lowercased() ?? "")",
                        Theme.accent.opacity(0.35))
            case .rejected:
                return ("REJECTED", Theme.danger, Theme.text(0.3), "plan rejected — session idle", Theme.hairline)
            case .refining:
                return ("REFINING", Theme.warning, Theme.warning, "refinement requested — re-drafting", Theme.warning.opacity(0.3))
            case .ready:
                return ("NEEDS YOU", Theme.warning, Theme.warning,
                        "plan ready for review · \(plan.steps.count) steps · waiting", Theme.warning.opacity(0.3))
            }
        }()
        return Button {
            app.path.append(.plan)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(plan.title)
                        .font(Theme.sans(14.5, .semibold))
                        .foregroundStyle(Theme.text)
                        .kerning(-0.15)
                        .lineLimit(1)
                    Spacer()
                    Text(badge)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(badgeColor)
                }
                .padding(.bottom, 6)
                Text(line)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                HStack(spacing: 10) {
                    Text(plan.project)
                    Text("ctx 31%")
                    Text("$1.12")
                    Spacer()
                    Text("grok-4.5 · plan")
                }
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
            .background(Theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.pinnedRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.pinnedRadius).stroke(border))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }

    // MARK: Project lists

    private var projectLists: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.projects) { project in
                let rows = project.sessions.filter { $0.id != app.sessionId || !$0.live }
                if !rows.isEmpty || project.custom {
                    SectionHeader(title: "\(project.name) — \(app.machine.name)")
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, 8)
                        .contextMenu {
                            if project.custom {
                                Button(role: .destructive) {
                                    app.engine?.deleteProject(id: project.id)
                                } label: {
                                    Label("Delete project", systemImage: "trash")
                                }
                            }
                        }
                    if rows.isEmpty {
                        Text("no sessions yet — long-press a session to move it here")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.raisedAlt)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.hairlineFaint))
                            .padding(.horizontal, Theme.gutter)
                            .padding(.bottom, 14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, session in
                                SessionRow(session: session, inProject: project)
                                if idx < rows.count - 1 {
                                    Divider().overlay(Theme.hairlineFaint)
                                }
                            }
                        }
                        .background(Theme.raisedAlt)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.hairlineFaint))
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }
}

private struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New project")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            Text("Group sessions under one name. Long-press any session to move it in.")
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.text(0.5))
                .padding(.bottom, 14)
            TextField("project name", text: $name)
                .font(Theme.mono(14))
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .onSubmit(create)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Theme.codeBlock)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(Theme.sans(12.5, .medium))
                        .foregroundStyle(Theme.text(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: create) {
                    Text("Create")
                        .font(Theme.sans(12.5, .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.accent.opacity(0.4) : Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        app.engine?.createProject(name: trimmed)
        dismiss()
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var app
    let session: SessionSummary
    var inProject: ProjectGroup? = nil

    var dotColor: Color {
        switch session.status {
        case .running: Theme.accent
        case .waiting: Theme.warning
        case .done: Theme.success
        case .idle: Theme.text(0.25)
        }
    }

    var metaLabel: String {
        let state: String = switch session.status {
        case .running: "live"
        case .waiting: "waiting"
        case .done: "merged"
        case .idle: "idle"
        }
        return "\(state) · \(session.ageLabel)"
    }

    var body: some View {
        Button {
            app.engine?.openSession(session)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(session.title)
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(metaLabel)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            let customProjects = app.projects.filter(\.custom)
            if !customProjects.isEmpty {
                ForEach(customProjects.filter { $0.id != inProject?.id }) { project in
                    Button {
                        app.engine?.moveCwd(session.cwd, toProject: project.id)
                    } label: {
                        Label("Move to \(project.name)", systemImage: "folder")
                    }
                }
            }
            if inProject?.custom == true {
                Button {
                    app.engine?.moveCwd(session.cwd, toProject: nil)
                } label: {
                    Label("Remove from \(inProject?.name ?? "project")", systemImage: "folder.badge.minus")
                }
            }
        }
    }
}

struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.offline {
            HStack(spacing: 8) {
                BlinkDot(color: Theme.danger, size: 6)
                Text("\(app.machine.name) unreachable — retrying")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.diffDelText)
                Spacer()
                Text("actions queue + sync")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.diffDelText.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(hex: 0x3C0E0A).opacity(0.88))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.danger.opacity(0.35)), alignment: .top)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.danger.opacity(0.35)), alignment: .bottom)
        }
    }
}

extension View {
    func chipBackground(border: Color) -> some View {
        self
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Theme.chip)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).stroke(border))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
