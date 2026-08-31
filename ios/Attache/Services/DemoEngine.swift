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
        app.approvalMode = .write
        app.rulesSummary = "12 · from 4 formats"
        app.mcpSummary = "3 connected"
        app.skillsSummary = "7 · 5"
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
        var groups = [
            ProjectGroup(id: "auto:~/src/pixeld", name: "pixeld", cwd: "~/src/pixeld", custom: false, sessions: [
                SessionSummary(id: "demo", title: "Fix decoder memory leak", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now, live: true, status: .running, shortId: "#9f31"),
                SessionSummary(id: "d2", title: "Batch export presets", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-7200), live: false, status: .done, shortId: "#31be"),
                SessionSummary(id: "d3", title: "Investigate AVIF encode speed", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-86_400), live: false, status: .idle, shortId: "#c04d"),
                SessionSummary(id: "d4", title: "⑂ leak fix — alt approach (branch)", project: "pixeld", cwd: "~/src/pixeld", sessionPath: "", updatedAt: now.addingTimeInterval(-10_800), live: false, status: .idle, shortId: "#b2e0"),
            ]),
            ProjectGroup(id: "auto:~/src/billing-api", name: "billing-api", cwd: "~/src/billing-api", custom: false, sessions: [
                SessionSummary(id: "plan1", title: "Ship usage-based invoicing", project: "billing-api", cwd: "~/src/billing-api", sessionPath: "", updatedAt: now.addingTimeInterval(-720), live: true, status: .waiting, shortId: "#77ac"),
            ]),
            ProjectGroup(id: "auto:~/src/omp-web", name: "omp-web", cwd: "~/src/omp-web", custom: false, sessions: [
                SessionSummary(id: "d5", title: "Docs search relevance pass", project: "omp-web", cwd: "~/src/omp-web", sessionPath: "", updatedAt: now.addingTimeInterval(-2 * 86_400), live: false, status: .idle, shortId: "#5aa1"),
            ]),
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

    func send(_ text: String, mode: ComposerMode, role: String) {
        guard let app else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
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
        guard let app else { return }
        guard let idx = app.approvals.firstIndex(where: { $0.id == id }) else { return }
        switch verdict {
        case .allow: app.approvals[idx].status = .allowed
        case .allowAlways: app.approvals[idx].status = .always
        case .deny: app.approvals[idx].status = .denied
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

    func branch(fromEntry: ChatItem) {
        guard let app else { return }
        let n = fromEntry.turn
        app.append(.steer("⑂ branched from turn \(n) → \"leak fix — alt approach\" · this session untouched"))
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
        ]
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
}
