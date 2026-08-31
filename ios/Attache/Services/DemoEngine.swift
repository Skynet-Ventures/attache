import Foundation

/// Scripted engine mirroring the design prototype's simulation: canned session,
/// agents, approvals, plan and machines. Used by "Explore with demo data" and
/// by App Store review. Timers stand in for real omp events.
@MainActor
final class DemoEngine: Engine {
    private weak var app: AppModel?
    private var replyTask: Task<Void, Never>?
    private var userMessageCount = 0

    func start(app: AppModel) {
        self.app = app
        app.machine = MachineStatus(
            name: "devbox", link: .demo, ompVersion: "17.3.4", bridgeVersion: "0.1.0", liveSessionCount: 2
        )
        app.sessionId = "demo"
        app.activeSummary = SessionSummary(
            id: "demo", title: "Fix decoder memory leak", project: "pixeld",
            cwd: "~/src/pixeld", sessionPath: "", updatedAt: Date(),
            live: true, status: .running, shortId: "#9f31", machineId: "devbox", machineName: "devbox"
        )
        app.sessionTitle = "Fix decoder memory leak"
        app.branchLabel = "⑂ fix/resize-pool"
        app.turnNo = 14
        app.elapsedSec = 1092
        app.ctxPercent = 66
        app.costUsd = 3.84
        app.modelLabel = "deepseek-v4"
        app.turnActive = true
        app.ctxLabel = ctxLabel(66)
        app.items = Self.initialStream()
        app.approvals = Self.initialQueue()
        app.subagents = Self.initialAgents()
        app.focusedAgentId = "reviewer"
        app.plan = Self.initialPlan()
        app.roles = Self.initialRoles()
        app.availableCommands = Self.demoCommands
        app.hubFeed = Self.initialHubFeed()
        app.enabledModels = [
            "fireworks/deepseek-v4-flash", "x-ai/grok-4.5", "anthropic/claude-opus-4.6",
            "anthropic/claude-sonnet-4.5", "zai/glm-5.2",
        ]
        app.approvalMode = .write
        app.rulesSummary = "12 · from 4 formats"
        app.mcpSummary = "3 connected"
        app.skillsSummary = "7 · 5"
        app.snapcompactLabel = "auto @ 85%"
        app.fallbackChain = ["deepseek-v4-flash", "nemotron-3-ultra", "glm-5.2"]
        app.pairedMachines = [
            PairedMachine(
                id: "devbox", name: "devbox", state: .online(latencyMs: 12),
                detail: "tailscale · 12ms · omp 17.3.4 · bun 1.4", sessionsLabel: "2 sessions live", canWake: false
            ),
            PairedMachine(
                id: "build-01", name: "build-01", state: .asleep,
                detail: "ssh relay · asleep 3h · wake-on-lan ready", sessionsLabel: "", canWake: true
            ),
        ]
        refreshSessions()
        app.startTicker()
    }

    /// Demo custom projects: name + claimed cwds.
    private var customProjects: [(id: String, name: String, cwds: [String])] = []

    func refreshSessions() {
        guard let app else { return }
        let now = Date()
        let tag = (machineId: "devbox", machineName: "devbox")
        var groups = [
            ProjectGroup(id: "auto:~/src/pixeld", name: "pixeld", cwd: "~/src/pixeld", custom: false, sessions: [
                SessionSummary(id: "demo", title: "Fix decoder memory leak", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now, live: true, status: .running, shortId: "#9f31", machineId: tag.machineId, machineName: tag.machineName),
                SessionSummary(id: "d2", title: "Batch export presets", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-7200), live: false, status: .done, shortId: "#31be", machineId: tag.machineId, machineName: tag.machineName),
                SessionSummary(id: "d3", title: "Investigate AVIF encode speed", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-86_400), live: false, status: .idle, shortId: "#c04d", machineId: tag.machineId, machineName: tag.machineName),
                SessionSummary(id: "d4", title: "⑂ leak fix — alt approach (branch)", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-10_800), live: false, status: .idle, shortId: "#b2e0", machineId: tag.machineId, machineName: tag.machineName),
            ], machineId: tag.machineId, machineName: tag.machineName),
            ProjectGroup(id: "auto:~/src/billing-api", name: "billing-api", cwd: "~/src/billing-api", custom: false, sessions: [
                SessionSummary(id: "plan1", title: "Ship usage-based invoicing", project: "billing-api", cwd: "~/src/billing-api", sessionPath: "", updatedAt: now.addingTimeInterval(-720), live: true, status: .waiting, shortId: "#77ac", machineId: tag.machineId, machineName: tag.machineName),
            ], machineId: tag.machineId, machineName: tag.machineName),
            ProjectGroup(id: "auto:~/src/omp-web", name: "omp-web", cwd: "~/src/omp-web", custom: false, sessions: [
                SessionSummary(id: "d5", title: "Docs search relevance pass", project: "omp-web", cwd: "~/src/omp-web", sessionPath: "", updatedAt: now.addingTimeInterval(-2 * 86_400), live: false, status: .idle, shortId: "#5aa1", machineId: tag.machineId, machineName: tag.machineName),
            ], machineId: tag.machineId, machineName: tag.machineName),
        ]
        // Apply custom-project claims the same way the bridge does.
        var custom: [ProjectGroup] = customProjects.map {
            ProjectGroup(id: $0.id, name: $0.name, cwd: $0.cwds.first ?? "", custom: true, sessions: [])
        }
        for i in groups.indices {
            if let ci = customProjects.firstIndex(where: { $0.cwds.contains(groups[i].cwd) }) {
                custom[ci].sessions.append(contentsOf: groups[i].sessions)
                groups[i].sessions = []
            }
        }
        app.projects = custom + groups.filter { !$0.sessions.isEmpty }
    }

    func createProject(name: String) {
        customProjects.append((id: UUID().uuidString, name: name, cwds: []))
        refreshSessions()
    }

    func deleteProject(id: String) {
        customProjects.removeAll { $0.id == id }
        refreshSessions()
    }

    func moveCwd(_ cwd: String, toProject projectId: String?) {
        for i in customProjects.indices {
            customProjects[i].cwds.removeAll { $0 == cwd }
        }
        if let projectId, let idx = customProjects.firstIndex(where: { $0.id == projectId }) {
            customProjects[idx].cwds.append(cwd)
        }
        refreshSessions()
    }

    func openSession(_ summary: SessionSummary) {
        guard let app else { return }
        if summary.id == "plan1" { app.path.append(.plan) } else { app.path.append(.stream) }
    }

    // MARK: Chat

    func send(_ text: String, mode: ComposerMode, role: String, attachments: [ComposerAttachment] = []) {
        guard let app else { return }
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if !attachments.isEmpty { trimmed += " 📎\(attachments.count)" }
        guard !trimmed.isEmpty else { return }
        if app.offline {
            app.append(.steer("queued: \"\(trimmed)\" — sends when devbox reconnects"))
            return
        }
        if mode == .goal, app.goal?.active != true {
            app.goal = GoalModel(objective: trimmed, turns: 1, budget: 40, active: true)
            app.append(.steer("goal pinned — hidden continuation steer active"))
            reply("Goal accepted. Working autonomously — each turn re-submits the objective until every deliverable is proven or the budget runs out.", bump: 2)
            return
        }
        if trimmed.hasPrefix("/") {
            app.append(.steer("\(trimmed) — accepted"))
            reply(trimmed.hasPrefix("/plan")
                ? "Entering plan mode: drafting a read-only proposal against grok-4.5. I'll hand back a structured plan for your review."
                : "Command accepted — applied to this session.", bump: 1)
            return
        }
        let prefix = mode == .chat ? "" : "[\(mode.rawValue.lowercased())] "
        app.append(.user(prefix + trimmed))
        let replies = [
            "Applied the defer in renderThumb and re-ran the load test — RSS flat at 212 MB over 5 m. Writing the pprof comparison next.",
            "Comparison written: alloc_space at resize.(*Pool).Get down 97%. Ready to open a PR when you are.",
            "Noted — adjusting and re-running the smallest relevant test.",
        ]
        reply(replies[min(userMessageCount, 2)], bump: 3)
        userMessageCount += 1
    }

    func stopTurn() {
        guard let app else { return }
        replyTask?.cancel()
        app.typing = false
        app.turnActive = false
        app.append(.steer("turn stopped — omp is idle, follow up to continue"))
    }

    private func reply(_ text: String, bump: Double, after: Double = 1.1) {
        guard let app else { return }
        app.typing = true
        replyTask = Task { [weak app] in
            try? await Task.sleep(for: .seconds(after))
            guard !Task.isCancelled, let app else { return }
            app.typing = false
            app.ctxPercent = min(84, app.ctxPercent + bump)
            app.ctxLabel = self.ctxLabel(app.ctxPercent)
            app.costUsd = (app.costUsd + 0.11)
            app.turnNo += 1
            if var g = app.goal, g.active {
                g.turns += 1
                app.goal = g
            }
            app.append(.agentText(text))
        }
    }

    private func ctxLabel(_ pct: Double) -> String {
        String(format: "%.1fk/200k", pct * 2)
    }

    // MARK: Approvals

    func resolveApproval(id: String, verdict: Verdict) {
        resolveApproval(id: id, verdict: verdict, scope: nil)
    }

    func resolveApproval(id: String, verdict: Verdict, scope: RuleScopeChoice?) {
        guard let app else { return }
        guard let idx = app.approvals.firstIndex(where: { $0.id == id }) else { return }
        switch verdict {
        case .allow: app.approvals[idx].status = .allowed
        case .allowAlways: app.approvals[idx].status = .always
        case .deny: app.approvals[idx].status = .denied
        }
        if verdict == .allowAlways {
            let scopeLabel = scope?.label ?? "Everywhere"
            app.append(.steer("rule added (always allow · \(scopeLabel))"))
        }
        // The inline stream card mirrors queue item q1.
        if id == "q1" {
            if let itemIdx = app.items.firstIndex(where: {
                if case .approval(let a) = $0.kind { return a.id == "q1" && a.status == .pending }
                return false
            }) {
                if case .approval(var a) = app.items[itemIdx].kind {
                    a.status = app.approvals[idx].status
                    app.items[itemIdx].kind = .approval(a)
                }
            }
            if verdict == .deny {
                reply("Understood — keeping the old baselines. I'll write the new profiles to tmp/profiles.new instead.", bump: 1)
            } else {
                if verdict == .allowAlways {
                    app.append(.steer("rule added: allow rm -rf under tmp/ for this project"))
                }
                app.append(.toolCard(ToolCardModel(
                    icon: "$", iconIsAccent: false, verb: "bash", subject: "rm -rf tmp/profiles.old",
                    meta: "exit 0 · 0.3s", detailLines: [], footer: nil,
                    addCount: nil, delCount: nil, hashline: nil
                )))
                reply("Baselines cleared. Re-running the 5-minute load with -memprofile for a clean comparison.", bump: 2)
            }
        }
    }

    // MARK: Advisor

    func advisorAddress(itemId: String) {
        guard let app else { return }
        setAdvisorState(itemId: itemId, state: .addressed)
        app.append(.steer("steer: address advisor note — defer Put() on error paths in renderThumb"))
        reply("Good catch from the advisor. Wrapping renderThumb's buffer in defer pool.Put(buf) so error paths release too — editing thumb.go now.", bump: 2)
    }

    func advisorDismiss(itemId: String) {
        setAdvisorState(itemId: itemId, state: .dismissed)
    }

    func advisorElaborate(itemId: String) {
        guard let app else { return }
        app.append(.steer("steer: ask advisor to elaborate — defer Put() on error paths in renderThumb"))
        reply("Elaborating: the cap alone doesn't fix the leak — the three Get() call sites that skip Put() on early returns still retain buffers. See cmd/loadgen/worker.go:141, batch.go:77, warm.go:19; a defer pool.Put(buf) in renderThumb covers all of them. Land the cap AND the defer together, then re-run the 5-minute load to prove RSS stays flat.", bump: 1)
    }

    private func setAdvisorState(itemId: String, state: AdvisorNoteModel.State) {
        guard let app else { return }
        guard let idx = app.items.firstIndex(where: { $0.id == itemId }) else { return }
        if case .advisor(var note) = app.items[idx].kind {
            note.state = state
            app.items[idx].kind = .advisor(note)
        }
    }

    // MARK: Subagents

    func steerSubagent(id: String, text: String) {
        guard let app else { return }
        guard let idx = app.subagents.firstIndex(where: { $0.id == id }) else { return }
        app.subagents[idx].transcript.append(SubagentLine(kind: .steer, text: text))
    }

    // MARK: Plan

    func planAccept() {
        guard let app, var plan = app.plan else { return }
        plan.state = .executing(step: 2)
        if !plan.steps.isEmpty { plan.steps[0].mark = .done }
        if plan.steps.count > 1 { plan.steps[1].mark = .active }
        app.plan = plan
    }

    func planReject() {
        guard let app, var plan = app.plan else { return }
        plan.state = .rejected
        app.plan = plan
    }

    func planRequestRedraft() {
        guard let app, var plan = app.plan else { return }
        plan.state = .ready
        app.plan = plan
    }

    func planRefine(_ text: String) {
        guard let app, var plan = app.plan else { return }
        plan.state = .refining
        app.plan = plan
        Task { [weak app] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let app, var p = app.plan else { return }
            p.state = .ready
            app.plan = p
        }
    }

    // MARK: Branch / diff

    func branchPoints() async -> [BranchPoint] {
        [
            BranchPoint(id: "e14", role: "user", preview: "Memory climbs ~40MB/min under thumbnail load until OOM…"),
            BranchPoint(id: "e13", role: "user", preview: "before advisor note"),
            BranchPoint(id: "e12", role: "user", preview: "before pool.go edit"),
        ]
    }

    func branch(entryId: String, preview: String) {
        guard let app else { return }
        app.append(.steer("⑂ branched before \"\(String(preview.prefix(48)))\" → \"leak fix — alt approach\" · this session untouched"))
    }

    func answerDialog(itemId: String, value: String?, confirmed: Bool?) {
        guard let app else { return }
        guard let idx = app.items.firstIndex(where: { $0.id == itemId }),
              case .dialog(var dialog) = app.items[idx].kind else { return }
        dialog.answered = value ?? (confirmed == true ? "yes" : "no")
        app.items[idx].kind = .dialog(dialog)
        reply("Got it — proceeding with \(dialog.answered ?? "that").", bump: 1)
    }

    func pickRole(_ role: String) {
        guard let app else { return }
        app.composerRole = role
        if let model = app.roles.first(where: { $0.name == role }) {
            app.modelLabel = model.model
            app.append(.steer("model → \(model.model)"))
        }
    }

    func setModel(_ fullModel: String) {
        guard let app else { return }
        let short = fullModel.split(separator: "/").last.map(String.init) ?? fullModel
        app.modelLabel = short
        app.append(.steer("model → \(short)"))
    }

    private var demoRules = [
        AlwaysRuleModel(id: "r1", tool: "bash", pattern: "rm -rf tmp/profiles.old", note: "allow bash: rm -rf tmp/profiles.old…", createdAt: "2026-08-30"),
        AlwaysRuleModel(id: "r2", tool: "mcp__github_create_pr", pattern: nil, note: "allow tool mcp__github_create_pr", createdAt: "2026-08-28"),
    ]

    func listRules() async -> [AlwaysRuleModel] { demoRules }

    func deleteRule(id: String) {
        demoRules.removeAll { $0.id == id }
    }

    func registerWebhook(_ url: String) async -> Bool {
        app?.webhookURL = url
        UserDefaults.standard.set(url, forKey: "push.webhook")
        return true
    }

    func testWebhook() async -> Bool { true }

    func startNewSession(cwd: String?, scratch: Bool) {
        guard let app else { return }
        app.items = []
        app.sessionTitle = scratch ? "Scratch session" : "New session"
        app.branchLabel = scratch ? "scratch" : (cwd as NSString?)?.lastPathComponent ?? "project"
        app.turnNo = 0
        app.ctxPercent = 2
        app.costUsd = 0
        app.append(.notice("fresh session in \(scratch ? "~/scratch" : cwd ?? "?") — say hi"))
        app.path.append(.stream)
    }

    func wake(mac: String) async -> Bool { true }

    func unpinSession() {
        guard let app else { return }
        app.sessionId = nil
        app.sessionTitle = ""
        app.turnActive = false
        refreshSessions()
    }

    func stopSession(id: String) {
        guard let app else { return }
        if app.sessionId == id { unpinSession() }
        for i in app.projects.indices {
            for j in app.projects[i].sessions.indices where app.projects[i].sessions[j].id == id {
                app.projects[i].sessions[j].status = .idle
                app.projects[i].sessions[j].live = false
            }
        }
    }

    func dispatchSubagent(task: String) {
        guard let app else { return }
        let name = "agent-\(app.subagents.count + 1)"
        app.subagents.append(SubagentModel(
            id: name, name: name, status: .queued,
            lastLine: "queued: \(String(task.prefix(60)))",
            meta: "dispatched just now", handle: "agent://new",
            transcript: [SubagentLine(kind: .text, text: "Queued: \(task)")]
        ))
    }

    func diffVerdict(approved: Bool, note: String?) {
        guard let app else { return }
        if approved {
            app.append(.steer("review: looks good — continue"))
        } else {
            let text = note?.isEmpty == false ? note! : "export a setter for maxRetained so loadgen can tune it"
            app.append(.steer("review: \(text)"))
            reply("Fair — adding SetMaxRetained(n) behind a testing build tag and updating the loadgen harness.", bump: 2)
        }
    }

    // MARK: Settings

    func cycleThinking(role: String) {
        guard let app else { return }
        guard let idx = app.roles.firstIndex(where: { $0.name == role }) else { return }
        app.roles[idx].thinking = app.roles[idx].thinking.next
    }

    func setApprovalMode(_ mode: ApprovalModeSetting) {
        app?.approvalMode = mode
    }

    func toggleHindsight() {
        app?.hindsightEnabled.toggle()
    }

    // MARK: Session QoL (demo canned)

    func renameSession(_ name: String) {
        guard let app else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        app.sessionTitle = trimmed
        app.append(.steer("session renamed → \(trimmed)"))
    }

    func fetchSessionStats() async -> [SessionStatRow] {
        [
            SessionStatRow(key: "sessionId", value: app?.sessionId ?? "demo"),
            SessionStatRow(key: "totalMessages", value: "214"),
            SessionStatRow(key: "userMessages", value: "38"),
            SessionStatRow(key: "assistantMessages", value: "61"),
            SessionStatRow(key: "toolCalls", value: "115"),
            SessionStatRow(key: "tokens (cumulative)", value: "184_221"),
            SessionStatRow(key: "cost", value: "3.84"),
            SessionStatRow(key: "contextUsage", value: "tokens 132400 / window 200k · 66%"),
        ]
    }

    func setFastMode(_ enabled: Bool) {
        guard let app else { return }
        app.fastModeActive = enabled
        app.append(.steer(enabled ? "fast mode on — snappier turns" : "fast mode off"))
    }

    func removeQueuedPrompt(id: String) {
        app?.items.removeAll { $0.id == id }
    }

    // MARK: Goal

    func goalPause() {
        guard let app, var g = app.goal else { return }
        g.active = false
        app.goal = g
        app.append(.steer("goal paused — resume with /goal"))
    }

    func goalDrop() {
        guard let app else { return }
        app.goal = nil
        app.append(.steer("goal dropped"))
    }

    // MARK: Machines

    func wakeMachine(id: String) {
        guard let app else { return }
        guard let idx = app.pairedMachines.firstIndex(where: { $0.id == id }), app.pairedMachines[idx].canWake else { return }
        app.pairedMachines[idx].state = .waking
        app.pairedMachines[idx].detail = "ssh relay · magic packet sent…"
        Task { [weak app] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let app, let i = app.pairedMachines.firstIndex(where: { $0.id == id }) else { return }
            app.pairedMachines[i].state = .online(latencyMs: 31)
            app.pairedMachines[i].detail = "ssh relay · 31ms · omp 17.3.4"
        }
    }

    func searchSessions(_ query: String) async -> [SessionSummary] {
        guard let app else { return [] }
        let q = query.lowercased()
        let all = app.projects.flatMap(\.sessions)
        if q.isEmpty { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.shortId.contains(q) }
    }

    // MARK: Post-beta roadmap (contracts A–I, demo canned)

    func handoff(instructions: String?) async -> HandoffResult {
        guard let app else { return HandoffResult(detail: "handoff.json", error: nil) }
        app.append(.steer("✉ handoff complete — ~/.omp/handoffs/handoff-\(app.turnNo).json"))
        if let notes = instructions, !notes.trimmingCharacters(in: .whitespaces).isEmpty {
            app.append(.notice("handoff notes: \(notes)"))
        }
        return HandoffResult(detail: "handoff-\(app.turnNo).json", error: nil)
    }

    func newSession(parent: SessionSummary, instructions: String?) {
        guard let app else { return }
        app.items = []
        app.subagents = []
        app.sessionTitle = "⑂ from \(parent.title)"
        app.branchLabel = parent.project
        app.turnNo = 0
        app.ctxPercent = 2
        app.costUsd = 0
        if let notes = instructions, !notes.trimmingCharacters(in: .whitespaces).isEmpty {
            app.append(.notice("context: \(notes)"))
        }
        app.append(.steer("⑂ new session from \"\(parent.title)\" — original untouched"))
        app.path.append(.stream)
    }

    func setQueueModes(
        steeringMode: QueueSteeringMode,
        followUpMode: QueueFollowUpMode,
        interruptMode: QueueInterruptMode
    ) {
        guard let app else { return }
        app.steeringMode = steeringMode
        app.followUpMode = followUpMode
        app.interruptMode = interruptMode
        app.append(.steer("queue: steering \(steeringMode.label.lowercased()) · follow-ups \(followUpMode.label.lowercased()) · interrupt \(interruptMode.label.lowercased())"))
    }

    func exportTranscript() async throws -> String {
        // A small but realistic standalone HTML transcript.
        let title = app?.sessionTitle ?? "demo session"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title) — transcript</title></head>
        <body><h1>\(title)</h1><p>Export from Attaché demo data — \(app?.items.count ?? 0) messages.</p></body></html>
        """
        return Data(html.utf8).base64EncodedString()
    }

    func fetchCostSummary(days: Int) async -> CostSummaryModel? {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var daysList: [CostDay] = []
        let samples: [(Double, Int, Int)] = [
            (0.84, 812_000, 41_000), (1.12, 1_010_000, 62_000), (0.47, 441_000, 23_000),
            (2.10, 1_820_000, 118_000), (1.63, 1_405_000, 97_000), (0.92, 760_000, 51_000),
        ]
        for i in stride(from: max(0, min(days, 30) - 1), through: 0, by: -1) {
            let day = formatter.string(from: now.addingTimeInterval(-Double(i) * 86_400))
            let s = samples[i % samples.count]
            daysList.append(CostDay(
                date: day, costUSD: s.0, tokensIn: s.1, tokensOut: s.2,
                sessions: i % 3 == 0 ? 2 : 1
            ))
        }
        return CostSummaryModel(
            days: daysList,
            byProject: [
                CostProjectRow(projectId: nil, cwd: "~/src/pixeld", costUSD: 3.41, sessions: 4),
                CostProjectRow(projectId: nil, cwd: "~/src/billing-api", costUSD: 2.10, sessions: 1),
                CostProjectRow(projectId: nil, cwd: "~/src/omp-web", costUSD: 1.57, sessions: 2),
                CostProjectRow(projectId: nil, cwd: "~/scratch", costUSD: 0.92, sessions: 6),
            ]
        )
    }

    func connectMachine(_ record: PairedMachineRecord) {
        guard let app else { return }
        app.pairedMachines.removeAll { $0.id == record.id }
        app.pairedMachines.insert(
            PairedMachine(
                id: record.id, name: record.name, state: .online(latencyMs: 18),
                detail: "tailscale · 18ms · omp 17.4.1", sessionsLabel: "0 sessions live", canWake: false
            ),
            at: 0
        )
        app.machine = MachineStatus(
            name: record.name, link: .online(latencyMs: 18), ompVersion: "17.4.1", bridgeVersion: "0.1.0", liveSessionCount: 0
        )
        refreshSessions()
    }

    func removeMachine(id: String) {
        guard let app else { return }
        app.pairedMachines.removeAll { $0.id == id }
        if let first = app.pairedMachines.first {
            app.machine = MachineStatus(
                name: first.name, link: .online(latencyMs: first.state == .online(latencyMs: 0) ? 12 : 18),
                ompVersion: "17.3.4", bridgeVersion: "0.1.0", liveSessionCount: 0
            )
        }
        refreshSessions()
    }

    func branchPoints(for summary: SessionSummary) async -> [BranchPoint] {
        // Stored sessions in the demo expose their last turns as fork points.
        [
            BranchPoint(id: "e\(summary.id.prefix(4))-1", role: "user", preview: summary.title),
            BranchPoint(id: "e\(summary.id.prefix(4))-2", role: "user", preview: "before the last edit"),
        ]
    }

    func branchStored(_ summary: SessionSummary, entryId: String, preview: String) {
        guard let app else { return }
        app.sessionTitle = "⑂ \(summary.title)"
        app.branchLabel = summary.project
        app.path.append(.stream)
        app.append(.steer("⑂ branched from stored session before \"\(String(preview.prefix(48)))\" · original untouched"))
    }

    // MARK: Seed data

    private static func initialStream() -> [ChatItem] {
        [
            ChatItem(kind: .user("Memory climbs ~40MB/min under thumbnail load until OOM. Find the leak in the resize pipeline and prove the fix with pprof."), turn: 12),
            ChatItem(kind: .agentText("Heap profile points at retained buffers in the resize pool. `sync.Pool` keeps every oversized buffer alive — unbounded-retention leak. Patching `Put()`:"), turn: 13),
            ChatItem(kind: .toolCard(ToolCardModel(
                icon: "✓", iconIsAccent: false, verb: "search", subject: "bytes.Buffer in internal/",
                meta: "14 hits",
                detailLines: [
                    DiffLine(kind: .context, text: "internal/resize/pool.go:14 bufPool sync.Pool"),
                    DiffLine(kind: .context, text: "internal/resize/thumb.go:88 buf := pool.Get()"),
                    DiffLine(kind: .context, text: "internal/encode/writer.go:31 bytes.Buffer scratch"),
                    DiffLine(kind: .context, text: "+ 11 more · open in files"),
                ],
                footer: nil, addCount: nil, delCount: nil, hashline: nil
            )), turn: 13),
            ChatItem(kind: .toolCard(ToolCardModel(
                icon: "±", iconIsAccent: true, verb: "edit", subject: "internal/resize/pool.go",
                meta: "",
                detailLines: [
                    DiffLine(kind: .hunk, text: "@@ -12,9 +12,16 @@ package resize"),
                    DiffLine(kind: .add, text: "+const maxRetained = 1 << 20 // 1 MiB"),
                    DiffLine(kind: .context, text: " var bufPool = sync.Pool{"),
                    DiffLine(kind: .context, text: "   New: func() any { return new(bytes.Buffer) },"),
                    DiffLine(kind: .context, text: " }"),
                    DiffLine(kind: .context, text: " func Put(b *bytes.Buffer) {"),
                    DiffLine(kind: .add, text: "+  if b.Cap() > maxRetained {"),
                    DiffLine(kind: .add, text: "+    return // drop oversized bufs"),
                    DiffLine(kind: .add, text: "+  }"),
                    DiffLine(kind: .context, text: "   b.Reset()"),
                    DiffLine(kind: .context, text: "   bufPool.Put(b)"),
                    DiffLine(kind: .context, text: " }"),
                ],
                footer: "lsp ✓ 0 diagnostics · gofmt ok",
                addCount: 11, delCount: 3, hashline: "#a3f2"
            )), turn: 13),
            ChatItem(kind: .advisor(AdvisorNoteModel(
                advisor: "advisor", severity: "concern",
                text: "Cap fix is right, but Get() callers skip Put() on the error path — the leak just moves. Suggest a defer in renderThumb.",
                modelLabel: "grok-4.5", afterTurn: 13
            )), turn: 13),
            ChatItem(kind: .approval(ApprovalModel(
                id: "q1", sessionId: "demo", sessionTitle: "Fix decoder memory leak",
                tool: "bash", risk: .high, riskDetail: "HIGH · BASH", source: "pixeld · 40s ago",
                command: "rm -rf tmp/profiles.old", diffLines: [],
                reason: "clear stale pprof baselines before re-comparing"
            )), turn: 14),
            ChatItem(kind: .approval(
                selfDiffBearingApproval(id: "q4", sessionId: "demo", sessionTitle: "Fix decoder memory leak", source: "pixeld · 1m")
            ), turn: 14),
        ]
    }

    /// A write approval whose command embeds a real multi-file unified diff —
    /// exercises the diff review surface end to end in demo mode.
    private static func selfDiffBearingApproval(
        id: String, sessionId: String, sessionTitle: String, source: String
    ) -> ApprovalModel {
        var approval = ApprovalModel(
            id: id, sessionId: sessionId, sessionTitle: sessionTitle,
            tool: "write", risk: .medium, riskDetail: "MED · WRITE",
            source: source, command: Self.demoApprovalDiff, diffLines: [],
            reason: "apply leak-fix diff to internal/resize/ (pool.go + thumb.go)"
        )
        if let parsed = BridgeEngine.parseDiffBlob(Self.demoApprovalDiff) {
            approval.diffLines = parsed.lines
        }
        return approval
    }

    private static func initialQueue() -> [ApprovalModel] {
        [
            ApprovalModel(
                id: "q1", sessionId: "demo", sessionTitle: "Fix decoder memory leak",
                tool: "bash", risk: .high, riskDetail: "HIGH · BASH", source: "pixeld · 40s ago",
                command: "rm -rf tmp/profiles.old", diffLines: [],
                reason: "clear stale pprof baselines before re-comparing"
            ),
            ApprovalModel(
                id: "q2", sessionId: "demo", sessionTitle: "Fix decoder memory leak",
                tool: "write", risk: .medium, riskDetail: "MED · WRITE OUTSIDE WORKSPACE", source: "pixeld · 2m",
                command: nil,
                diffLines: [
                    DiffLine(kind: .del, text: "− vision: grok-4.5:medium"),
                    DiffLine(kind: .add, text: "+ vision: grok-4.5:high"),
                ],
                reason: "~/.omp/agent/models.yml — bump vision thinking level"
            ),
            ApprovalModel(
                id: "q3", sessionId: "plan1", sessionTitle: "Ship usage-based invoicing",
                tool: "mcp__github_create_pr", risk: .low, riskDetail: "LOW · MCP", source: "billing-api · 12m",
                command: nil, diffLines: [],
                reason: "github.create_pr — \"invoicing: metered usage rollups\" → base main, draft"
            ),
            selfDiffBearingApproval(id: "q4", sessionId: "demo", sessionTitle: "Fix decoder memory leak", source: "pixeld · 1m"),
        ]
    }

    private static func initialAgents() -> [SubagentModel] {
        [
            SubagentModel(
                id: "explore", name: "explore", status: .live,
                lastLine: "tracing Get() callers across cmd/loadgen…",
                meta: "2m14s · 8.1k tok · 12 calls", handle: "agent://b2c9",
                transcript: [
                    SubagentLine(kind: .tool, text: "search Get( in cmd/", meta: "22 hits"),
                    SubagentLine(kind: .tool, text: "read cmd/loadgen/worker.go", meta: "0.3s"),
                    SubagentLine(kind: .text, text: "Three call sites never return buffers on error. Flagging worker.go:141, batch.go:77, warm.go:19 for the defer fix."),
                ]
            ),
            SubagentModel(
                id: "reviewer", name: "reviewer", status: .live,
                lastLine: "reviewing pool.go diff for API breakage",
                meta: "41s · 3.3k tok · 4 calls", handle: "agent://7f31",
                transcript: [
                    SubagentLine(kind: .tool, text: "read internal/resize/pool.go", meta: "0.4s"),
                    SubagentLine(kind: .text, text: "Public API unchanged. One concern: maxRetained is package-private — loadgen tests can't tune it. Consider exporting a setter or build tag."),
                ]
            ),
            SubagentModel(
                id: "librarian", name: "librarian", status: .done,
                lastLine: "sync.Pool retention semantics — 3 sources",
                meta: "done · 5.9k tok · report ready", handle: "agent://ce02",
                transcript: [
                    SubagentLine(kind: .tool, text: "fetch go.dev/doc — sync.Pool notes", meta: "1.1s"),
                    SubagentLine(kind: .text, text: "Report: pools drop objects on GC; capping retained capacity at Put() is the canonical fix (see runtime issue #23199)."),
                ]
            ),
            SubagentModel(
                id: "oracle", name: "oracle", status: .queued,
                lastLine: "queued: sanity-check pprof methodology",
                meta: "waiting on reviewer", handle: "agent://—",
                transcript: [
                    SubagentLine(kind: .text, text: "Queued. Will compare alloc_space before/after under identical load once reviewer signs off."),
                ]
            ),
        ]
    }

    private static func initialPlan() -> PlanModel {
        PlanModel(
            title: "Ship usage-based invoicing",
            project: "billing-api",
            roleLabel: "billing-api · plan role · grok-4.5:high",
            summary: "Meter usage per account, roll up hourly, price by tier, and land invoice line items behind a flag. 14 files in scope · est. 2 sessions.",
            steps: [
                PlanStepModel(title: "Add usage_events table + backfill migration", file: "db/migrations/0142_usage_events.sql", risk: .medium),
                PlanStepModel(title: "Hourly metered rollup job", file: "jobs/rollup.go", risk: .low),
                PlanStepModel(title: "Tiered price resolver", file: "billing/price.go", risk: .low),
                PlanStepModel(title: "Invoice line-item generator changes", file: "billing/invoice.go", risk: .high),
                PlanStepModel(title: "Backfill dry-run + reconciliation report", file: "scripts/reconcile.go", risk: .medium),
                PlanStepModel(title: "Feature flag + staged rollout", file: "config/flags.yml", risk: .low),
            ]
        )
    }

    private static func initialRoles() -> [RoleModel] {
        [
            RoleModel(name: "default", model: "deepseek-v4-flash", thinking: .max),
            RoleModel(name: "plan", model: "grok-4.5", thinking: .high),
            RoleModel(name: "slow", model: "claude-opus-4.6", thinking: .xhigh),
            RoleModel(name: "task", model: "deepseek-v4-flash", thinking: .medium),
            RoleModel(name: "smol", model: "deepseek-v4-flash", thinking: .low),
            RoleModel(name: "vision", model: "grok-4.5", thinking: .medium),
            RoleModel(name: "designer", model: "claude-sonnet-4.5", thinking: .high),
            RoleModel(name: "advisor", model: "grok-4.5", thinking: .high),
        ]
    }

    /// Canned slash commands so the palette works in demo mode (the bridge
    /// would normally forward omp's `available_commands_update`).
    private static let demoCommands: [SlashCommand] = [
        SlashCommand(name: "/plan", source: "builtin", aliases: ["/p"], summary: "draft a structured plan for review", hint: "<objective>"),
        SlashCommand(name: "/goal", source: "builtin", summary: "pin an objective and work until proven", hint: "<objective>"),
        SlashCommand(name: "/loop", source: "builtin", summary: "resubmit a prompt N times", hint: "<n> <prompt>"),
        SlashCommand(name: "/compact", source: "builtin", summary: "snapcompact the context now"),
        SlashCommand(name: "/resume", source: "builtin", summary: "open the session picker"),
        SlashCommand(name: "/new", source: "builtin", summary: "start a new saved session"),
        SlashCommand(name: "/agents", source: "builtin", summary: "open the agent hub"),
        SlashCommand(name: "/handoff", source: "extension", summary: "hand the session off to another machine", hint: "<instructions?>", subcommands: [
            SlashCommand(name: "/handoff to", source: "extension", summary: "hand off with no instructions"),
            SlashCommand(name: "/handoff with", source: "extension", summary: "hand off with custom instructions", hint: "<instructions>"),
        ]),
    ]
    
    /// Canned Comms feed entries so the agents screen exercises the hub feed
    /// rendering in demo mode (goal change highlighted, sender badges).
    private static func initialHubFeed() -> [HubMessage] {
        let now = Date()
        return [
            HubMessage(
                kind: .message, sender: "librarian",
                text: "Pool retention is GC-scoped; capping capacity at Put() is the canonical fix (runtime#23199).",
                timestamp: now.addingTimeInterval(-310)
            ),
            HubMessage(
                kind: .goal, sender: nil, text: "goal accepted",
                goalObjective: "Fix decoder memory leak", goalStatus: "active",
                timestamp: now.addingTimeInterval(-290)
            ),
            HubMessage(
                kind: .message, sender: "reviewer",
                text: "pool.go diff reviewed — no API breakage, but maxRetained is package-private; loadgen can't tune it.",
                timestamp: now.addingTimeInterval(-120)
            ),
            HubMessage(
                kind: .notice, sender: "omp", text: "context at 66% — auto compaction at 85%",
                level: "info",
                timestamp: now.addingTimeInterval(-60)
            ),
        ]
    }

    /// A multi-file unified diff embedded in an approval command, exactly as
    /// omp's write-approval prompt can carry it.
    static let demoApprovalDiff = """
    diff --git a/internal/resize/pool.go b/internal/resize/pool.go
    index 1f2a3b4..9c8d7e6 100644
    --- a/internal/resize/pool.go
    +++ b/internal/resize/pool.go
    @@ -12,9 +12,16 @@ package resize
     const maxRetained = 1 << 20 // 1 MiB
    -New: func() any { return new(bytes.Buffer) },
    +func makeBuffer() *bytes.Buffer { return new(bytes.Buffer) }
    +
    +func New() any { return makeBuffer() }
     func Put(b *bytes.Buffer) {
    +	if b.Cap() > maxRetained {
    +		return // drop oversized bufs
    +	}
    +	bufPool.Put(b)
    -	bufPool.Put(b)
     }
    diff --git a/internal/resize/thumb.go b/internal/resize/thumb.go
    index 77a1b2c..d4e5f6a 100644
    --- a/internal/resize/thumb.go
    +++ b/internal/resize/thumb.go
    @@ -86,7 +86,11 @@ func renderThumb(ctx context.Context) ([]byte, error) {
     	buf := pool.Get()
    +	defer pool.Put(buf)
     	if err := decode(r, buf); err != nil {
    -		return nil, err
     	}
     	return encode(buf)
    @@ -101,6 +105,9 @@ func encode(buf *bytes.Buffer) ([]byte, error) {
    +	scratch := buf.Bytes()
    +	n := copy(out, scratch)
    +	_ = n
     	return out, nil
     }
    """
}
