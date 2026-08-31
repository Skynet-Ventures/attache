import Foundation

/// Live engine: drives AppModel from a paired attache-bridge over WebSocket.
@MainActor
final class BridgeEngine: Engine {
    private weak var app: AppModel?
    private let pairing: PairingInfo
    private var client: BridgeClient?
    /// Streaming assistant text accumulates into one chat item per message.
    private var streamingItemId: String?
    /// toolCallId -> chat item id, for updating running tool cards.
    private var toolItems: [String: String] = [:]
    private var subagentsById: [String: SubagentModel] = [:]

    init(pairing: PairingInfo) {
        self.pairing = pairing
    }

    func start(app: AppModel) {
        self.app = app
        // Clear any state left over from demo mode or a previous pairing.
        app.items = []
        app.approvals = []
        app.subagents = []
        app.plan = nil
        app.goal = nil
        app.projects = []
        app.sessionId = nil
        app.sessionTitle = ""
        app.turnActive = false
        app.typing = false
        app.machine = MachineStatus(
            name: pairing.machineName, link: .connecting, ompVersion: "", bridgeVersion: "", liveSessionCount: 0
        )
        let client = BridgeClient(host: pairing.host, token: pairing.token)
        self.client = client
        client.onStateChange = { [weak self] state in
            guard let self, let app = self.app else { return }
            switch state {
            case .connected:
                app.offline = false
                app.machine.link = .online(latencyMs: 0)
                Task { await self.handshake() }
            case .offline:
                app.offline = true
                app.machine.link = .offline
            case .connecting:
                app.machine.link = .connecting
            case .idle:
                break
            }
        }
        client.onEvent = { [weak self] type, frame in
            self?.handleEvent(type: type, frame: frame)
        }
        client.connect()
        app.startTicker()
    }

    private func handshake() async {
        guard let client, let app else { return }
        do {
            let hello = try await client.send("hello", ["protocolVersion": 1])
            if let machine = hello["machine"] {
                app.machine = MachineStatus(
                    name: machine["name"]?.stringValue ?? pairing.machineName,
                    link: .online(latencyMs: 0),
                    ompVersion: machine["ompVersion"]?.stringValue ?? "",
                    bridgeVersion: machine["bridgeVersion"]?.stringValue ?? "",
                    liveSessionCount: 0
                )
            }
            if let roles = hello["roles"]?.arrayValue {
                app.roles = roles.compactMap(roleModel)
            }
            if let mode = hello["approvalMode"]?.stringValue,
               let parsed = ApprovalModeSetting(rawValue: mode) {
                app.approvalMode = parsed
            }
            app.pairedMachines = [
                PairedMachine(
                    id: "paired", name: app.machine.name, state: .online(latencyMs: 0),
                    detail: "tailscale · omp \(app.machine.ompVersion) · bridge \(app.machine.bridgeVersion)",
                    sessionsLabel: "", canWake: false
                ),
            ]
            refreshSessions()
        } catch {
            // Reconnect loop will retry the handshake.
        }
    }

    private func roleModel(_ value: JSONValue) -> RoleModel? {
        guard let name = value["role"]?.stringValue, let model = value["model"]?.stringValue else { return nil }
        let shortModel = model.split(separator: "/").last.map(String.init) ?? model
        let level = value["thinkingLevel"]?.stringValue.flatMap(ThinkingLevel.init(rawValue:)) ?? .medium
        return RoleModel(name: name, model: shortModel, thinking: level)
    }

    // MARK: Sessions

    func refreshSessions() {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            guard let data = try? await client.send("list_sessions") else { return }
            guard let projects = data["projects"]?.arrayValue else { return }
            app.projects = projects.compactMap { p in
                guard let name = p["name"]?.stringValue else { return nil }
                let cwd = p["cwd"]?.stringValue ?? ""
                let sessions = (p["sessions"]?.arrayValue ?? []).compactMap(self.sessionSummary)
                return ProjectGroup(
                    id: p["id"]?.stringValue ?? "auto:\(cwd)",
                    name: name,
                    cwd: cwd,
                    custom: p["custom"]?.boolValue ?? false,
                    sessions: sessions
                )
            }
            app.machine.liveSessionCount = app.projects.flatMap(\.sessions).filter(\.live).count
        }
    }

    private func sessionSummary(_ value: JSONValue) -> SessionSummary? {
        guard let id = value["id"]?.stringValue, let title = value["title"]?.stringValue else { return nil }
        let updated = value["updatedAt"]?.stringValue.flatMap { ISO8601DateFormatter.flexible.date(from: $0) } ?? Date()
        let status: SessionSummary.Status = switch value["status"]?.stringValue {
        case "running": .running
        case "waiting": .waiting
        default: .idle
        }
        return SessionSummary(
            id: id,
            title: title,
            project: value["project"]?.stringValue ?? "",
            cwd: value["cwd"]?.stringValue ?? "",
            sessionPath: value["sessionPath"]?.stringValue ?? "",
            updatedAt: updated,
            live: value["live"]?.boolValue ?? false,
            status: status,
            shortId: value["shortId"]?.stringValue ?? ""
        )
    }

    func openSession(_ summary: SessionSummary) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            app.items = []
            app.subagents = []
            app.sessionTitle = summary.title
            app.branchLabel = summary.project
            app.sessionId = nil
            app.path.append(.stream)
            do {
                var payload: [String: Any] = [:]
                if summary.live {
                    payload["sessionId"] = summary.id
                } else if !summary.sessionPath.isEmpty {
                    payload["sessionPath"] = summary.sessionPath
                    payload["cwd"] = summary.cwd
                } else {
                    payload["cwd"] = summary.cwd
                }
                let result = try await client.send("attach", payload)
                app.sessionId = result["sessionId"]?.stringValue
                await self.loadHistory()
                _ = try? await client.send("get_subagents", ["sessionId": app.sessionId ?? ""])
                self.refreshSubagents()
            } catch {
                app.append(.notice("couldn't attach: \((error as? BridgeError)?.message ?? "unknown error")"))
            }
        }
    }

    private func loadHistory() async {
        guard let client, let app, let sessionId = app.sessionId else { return }
        var cursor: String?
        var pages = 0
        repeat {
            var payload: [String: Any] = ["sessionId": sessionId, "limit": 256]
            if let cursor { payload["cursor"] = cursor }
            guard let data = try? await client.send("get_messages", payload) else { break }
            for message in data["messages"]?.arrayValue ?? [] {
                appendHistoryMessage(message)
            }
            cursor = data["nextCursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 40
    }

    private func appendHistoryMessage(_ value: JSONValue) {
        guard let app else { return }
        let message = value["message"] ?? value
        let role = message["role"]?.stringValue ?? ""
        let blocks = message["content"]?.arrayValue ?? []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                guard var text = block["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                if role == "user" {
                    if let advisory = extractAdvisory(text) {
                        app.append(.advisor(advisory))
                    } else if text.hasPrefix("[steer") || text.hasPrefix("steer:") {
                        app.append(.steer(text))
                    } else {
                        text = String(text.prefix(4000))
                        app.append(.user(text))
                    }
                } else if role == "assistant" {
                    app.append(.agentText(String(text.prefix(8000))))
                }
            case "toolCall", "tool_call", "toolUse":
                let name = block["name"]?.stringValue ?? block["toolName"]?.stringValue ?? "tool"
                app.append(.toolCard(toolCard(name: name, args: block["arguments"] ?? block["input"], result: nil)))
            default:
                continue
            }
        }
    }

    // MARK: Event handling

    private func handleEvent(type: String, frame: JSONValue) {
        guard let app else { return }
        switch type {
        case "session_state":
            applyState(frame["state"])
        case "stream":
            guard frame["sessionId"]?.stringValue == app.sessionId else { return }
            handleStreamEvent(frame["event"] ?? .null)
        case "approval_request":
            handleApprovalRequest(frame["approval"] ?? .null)
        case "approval_resolved":
            handleApprovalResolved(frame)
        case "advisor":
            handleAdvisorEvent(frame["note"] ?? .null)
        case "subagent":
            refreshSubagents()
        case "sessions_changed":
            refreshSessions()
        default:
            break
        }
    }

    private func applyState(_ state: JSONValue?) {
        guard let app, let state else { return }
        guard state["sessionId"]?.stringValue == app.sessionId || app.sessionId == nil else { return }
        if let name = state["sessionName"]?.stringValue, !name.isEmpty { app.sessionTitle = name }
        if let model = state["model"] {
            let id = model["id"]?.stringValue ?? ""
            app.modelLabel = id.split(separator: "/").last.map(String.init) ?? id
        }
        if let ctx = state["contextUsage"] {
            let tokens = ctx["tokens"]?.doubleValue ?? 0
            let window = ctx["contextWindow"]?.doubleValue ?? 1
            app.ctxPercent = min(100, tokens / max(window, 1) * 100)
            app.ctxLabel = String(format: "%.1fk/%.0fk", tokens / 1000, window / 1000)
        }
        if let cost = state["costUsd"]?.doubleValue { app.costUsd = cost }
        if let turn = state["turn"]?.intValue, turn > 0 { app.turnNo = turn }
        let streaming = state["isStreaming"]?.boolValue ?? false
        app.turnActive = streaming
        if !streaming { app.typing = false }
    }

    private func handleStreamEvent(_ event: JSONValue) {
        guard let app else { return }
        switch event["type"]?.stringValue {
        case "agent_start":
            app.typing = true
            app.turnActive = true
            app.turnStartedAt = Date()
        case "turn_start":
            app.turnNo += 1
            if var goal = app.goal, goal.active {
                goal.turns += 1
                app.goal = goal
            }
        case "agent_end":
            if event["isTerminal"]?.boolValue != false {
                app.typing = false
                app.turnActive = false
                app.turnStartedAt = nil
                streamingItemId = nil
                NotificationManager.shared.notifyTurnDone(sessionTitle: app.sessionTitle)
            }
        case "message_start":
            streamingItemId = nil
        case "message_update":
            handleDelta(event)
        case "message_end":
            finalizeMessage(event)
        case "tool_execution_start":
            let name = event["toolName"]?.stringValue ?? event["name"]?.stringValue ?? "tool"
            var card = toolCard(name: name, args: event["args"] ?? event["arguments"], result: nil)
            card.running = true
            let item = ChatItem(kind: .toolCard(card), turn: app.turnNo)
            app.items.append(item)
            if let callId = event["toolCallId"]?.stringValue { toolItems[callId] = item.id }
            streamingItemId = nil
        case "tool_execution_end":
            guard let callId = event["toolCallId"]?.stringValue,
                  let itemId = toolItems[callId],
                  let idx = app.items.firstIndex(where: { $0.id == itemId }),
                  case .toolCard(var card) = app.items[idx].kind else { return }
            card.running = false
            card.meta = toolResultMeta(event["result"]) ?? card.meta
            app.items[idx].kind = .toolCard(card)
        case "session_exited":
            app.append(.notice("session process ended on \(app.machine.name)"))
            app.turnActive = false
            app.typing = false
        default:
            break
        }
    }

    private func handleDelta(_ event: JSONValue) {
        guard let app else { return }
        guard let assistantEvent = event["assistantMessageEvent"],
              assistantEvent["type"]?.stringValue == "text_delta",
              let delta = assistantEvent["delta"]?.stringValue, !delta.isEmpty else { return }
        app.typing = false
        if let id = streamingItemId,
           let idx = app.items.firstIndex(where: { $0.id == id }),
           case .agentText(let text) = app.items[idx].kind {
            app.items[idx].kind = .agentText(text + delta)
        } else {
            let item = ChatItem(kind: .agentText(delta), turn: app.turnNo)
            app.items.append(item)
            streamingItemId = item.id
        }
    }

    private func finalizeMessage(_ event: JSONValue) {
        guard let app else { return }
        streamingItemId = nil
        // Advisor injections arrive as finalized custom/user messages.
        let message = event["message"] ?? .null
        for block in message["content"]?.arrayValue ?? [] {
            if let text = block["text"]?.stringValue, let advisory = extractAdvisory(text) {
                app.append(.advisor(advisory))
            }
        }
    }

    private func extractAdvisory(_ text: String) -> AdvisorNoteModel? {
        guard text.contains("<advisory") else { return nil }
        guard let open = text.range(of: ">", range: text.range(of: "<advisory")!.upperBound..<text.endIndex),
              let close = text.range(of: "</advisory>") else { return nil }
        let body = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        func attr(_ name: String) -> String? {
            guard let r = text.range(of: "\(name)=\"") else { return nil }
            guard let end = text.range(of: "\"", range: r.upperBound..<text.endIndex) else { return nil }
            return String(text[r.upperBound..<end.lowerBound])
        }
        return AdvisorNoteModel(
            advisor: attr("advisor") ?? "advisor",
            severity: attr("severity") ?? "concern",
            text: body,
            modelLabel: "advisor",
            afterTurn: app?.turnNo ?? 0
        )
    }

    // MARK: Tool card shaping

    private func toolCard(name: String, args: JSONValue?, result: JSONValue?) -> ToolCardModel {
        var subject = ""
        if let args {
            subject = args["command"]?.stringValue
                ?? args["path"]?.stringValue
                ?? args["file_path"]?.stringValue
                ?? args["pattern"]?.stringValue
                ?? args["query"]?.stringValue
                ?? args["url"]?.stringValue
                ?? ""
        }
        let icon: String
        var accent = false
        switch name {
        case "bash", "eval": icon = "$"
        case "edit", "write", "ast_edit": icon = "±"; accent = true
        case "read": icon = "≡"
        case "grep", "glob": icon = "✓"
        case "task": icon = "◇"; accent = true
        default: icon = "·"
        }
        return ToolCardModel(
            icon: icon, iconIsAccent: accent, verb: name,
            subject: String(subject.prefix(120)), meta: "",
            detailLines: [], footer: nil, addCount: nil, delCount: nil, hashline: nil
        )
    }

    private func toolResultMeta(_ result: JSONValue?) -> String? {
        guard let result else { return nil }
        if let exit = result["exitCode"]?.intValue { return "exit \(exit)" }
        if let text = result["content"]?.arrayValue?.first?["text"]?.stringValue {
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            return String(first.prefix(28))
        }
        return "done"
    }

    // MARK: Approvals

    private func handleApprovalRequest(_ value: JSONValue) {
        guard let app, let id = value["id"]?.stringValue else { return }
        let sessionId = value["sessionId"]?.stringValue ?? ""
        let tool = value["tool"]?.stringValue ?? "tool"
        let risk: RiskLevel = RiskLevel(rawValue: value["risk"]?.stringValue ?? "medium") ?? .medium
        let approval = ApprovalModel(
            id: id,
            sessionId: sessionId,
            sessionTitle: app.sessionTitle,
            tool: tool,
            risk: risk,
            riskDetail: "\(risk.label) · \(tool.uppercased())",
            source: "\(app.machine.name) · now",
            command: value["command"]?.stringValue,
            diffLines: [],
            reason: value["reason"]?.stringValue ?? value["prompt"]?.stringValue ?? ""
        )
        app.approvals.insert(approval, at: 0)
        if sessionId == app.sessionId {
            app.items.append(ChatItem(kind: .approval(approval), turn: app.turnNo))
        }
        NotificationManager.shared.notifyApproval(approval, host: pairing.host)
    }

    private func handleApprovalResolved(_ frame: JSONValue) {
        guard let app, let approvalId = frame["approvalId"]?.stringValue else { return }
        let verdict = frame["verdict"]?.stringValue ?? "allow"
        let by = frame["by"]?.stringValue ?? "app"
        let status: ApprovalModel.Status = verdict == "deny" ? .denied : (verdict == "allow_always" ? .always : .allowed)
        if let idx = app.approvals.firstIndex(where: { $0.id == approvalId }) {
            app.approvals[idx].status = status
        }
        if let idx = app.items.firstIndex(where: {
            if case .approval(let a) = $0.kind { return a.id == approvalId }
            return false
        }), case .approval(var a) = app.items[idx].kind {
            a.status = status
            app.items[idx].kind = .approval(a)
        }
        if by == "rule", let note = frame["ruleNote"]?.stringValue {
            app.append(.steer("auto-approved by rule: \(note)"))
        } else if verdict == "allow_always", let note = frame["ruleNote"]?.stringValue {
            app.append(.steer("rule added: \(note)"))
        }
        NotificationManager.shared.clearApprovalNotification(id: approvalId)
    }

    private func handleAdvisorEvent(_ note: JSONValue) {
        guard let app else { return }
        guard note["sessionId"]?.stringValue == app.sessionId else { return }
        app.append(.advisor(AdvisorNoteModel(
            advisor: note["advisor"]?.stringValue ?? "advisor",
            severity: note["severity"]?.stringValue ?? "concern",
            text: note["text"]?.stringValue ?? "",
            modelLabel: note["advisor"]?.stringValue ?? "advisor",
            afterTurn: app.turnNo
        )))
        NotificationManager.shared.notifyAdvisor(sessionTitle: app.sessionTitle)
    }

    // MARK: Subagents

    private func refreshSubagents() {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            guard let data = try? await client.send("get_subagents", ["sessionId": sessionId]) else { return }
            let entries = data["subagents"]?.arrayValue ?? data.arrayValue ?? []
            var models: [SubagentModel] = []
            for entry in entries {
                guard let id = entry["id"]?.stringValue ?? entry["subagentId"]?.stringValue else { continue }
                let name = entry["name"]?.stringValue ?? entry["agent"]?.stringValue ?? id
                let statusText = entry["status"]?.stringValue ?? entry["state"]?.stringValue ?? "live"
                let status: SubagentModel.Status =
                    ["done", "completed", "finished"].contains(statusText) ? .done
                    : ["queued", "pending", "waiting"].contains(statusText) ? .queued
                    : .live
                var model = subagentsById[id] ?? SubagentModel(
                    id: id, name: name, status: status, lastLine: "", meta: "",
                    handle: "agent://\(id.prefix(4))", transcript: []
                )
                model.status = status
                model.lastLine = entry["lastLine"]?.stringValue ?? entry["title"]?.stringValue ?? model.lastLine
                models.append(model)
                subagentsById[id] = model
                await self.loadSubagentTranscript(id: id)
            }
            app.subagents = models.isEmpty ? app.subagents : models
        }
    }

    private func loadSubagentTranscript(id: String) async {
        guard let client, let app, let sessionId = app.sessionId else { return }
        guard let data = try? await client.send("get_subagent_messages", ["sessionId": sessionId, "subagentId": id]) else { return }
        var lines: [SubagentLine] = []
        for message in data["messages"]?.arrayValue ?? [] {
            let m = message["message"] ?? message
            for block in m["content"]?.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text":
                    if m["role"]?.stringValue == "assistant", let text = block["text"]?.stringValue, !text.isEmpty {
                        lines.append(SubagentLine(kind: .text, text: String(text.prefix(600))))
                    }
                case "toolCall", "tool_call", "toolUse":
                    let name = block["name"]?.stringValue ?? "tool"
                    let arg = block["arguments"]?["command"]?.stringValue
                        ?? block["arguments"]?["path"]?.stringValue ?? ""
                    lines.append(SubagentLine(kind: .tool, text: "\(name) \(String(arg.prefix(60)))"))
                default:
                    break
                }
            }
        }
        if var model = subagentsById[id] {
            model.transcript = Array(lines.suffix(12))
            if model.lastLine.isEmpty, let last = lines.last(where: { $0.kind == .text }) {
                model.lastLine = last.text
            }
            subagentsById[id] = model
            if let idx = app.subagents.firstIndex(where: { $0.id == id }) {
                app.subagents[idx] = model
            }
        }
    }

    // MARK: Engine intents

    func send(_ text: String, mode: ComposerMode, role: String) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if app.offline {
                app.append(.steer("queued: \"\(trimmed)\" — sends when \(app.machine.name) reconnects"))
                return
            }
            let prefix = mode == .chat ? "" : "[\(mode.rawValue.lowercased())] "
            app.append(.user(prefix + trimmed))
            if mode == .goal {
                app.goal = GoalModel(objective: trimmed, turns: 1, budget: 40, active: true)
            }
            do {
                var payload: [String: Any] = [
                    "sessionId": sessionId,
                    "message": trimmed,
                    "mode": mode.rawValue.lowercased(),
                ]
                if app.turnActive { payload["streamingBehavior"] = "steer" }
                try await client.send("prompt", payload)
            } catch {
                app.append(.notice("send failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func stopTurn() {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            try? await client.send("abort", ["sessionId": sessionId])
            app.turnActive = false
            app.typing = false
            app.append(.steer("turn stopped — omp is idle, follow up to continue"))
        }
    }

    func resolveApproval(id: String, verdict: Verdict) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            let sessionId = app.approvals.first(where: { $0.id == id })?.sessionId ?? app.sessionId ?? ""
            try? await client.send("approval_verdict", [
                "sessionId": sessionId, "approvalId": id, "verdict": verdict.rawValue,
            ])
        }
    }

    func advisorAddress(itemId: String) {
        guard let app else { return }
        guard let idx = app.items.firstIndex(where: { $0.id == itemId }),
              case .advisor(var note) = app.items[idx].kind else { return }
        note.state = .addressed
        app.items[idx].kind = .advisor(note)
        let text = note.text
        Task { [weak self] in
            guard let self, let client = self.client, let sessionId = self.app?.sessionId else { return }
            self.app?.append(.steer("steer: address advisor note — \(String(text.prefix(120)))"))
            try? await client.send("steer", [
                "sessionId": sessionId,
                "message": "Address this advisor note: \(text)",
            ])
        }
    }

    func advisorDismiss(itemId: String) {
        guard let app else { return }
        guard let idx = app.items.firstIndex(where: { $0.id == itemId }),
              case .advisor(var note) = app.items[idx].kind else { return }
        note.state = .dismissed
        app.items[idx].kind = .advisor(note)
    }

    func steerSubagent(id: String, text: String) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            if let idx = app.subagents.firstIndex(where: { $0.id == id }) {
                app.subagents[idx].transcript.append(SubagentLine(kind: .steer, text: text))
                self.subagentsById[id] = app.subagents[idx]
            }
            try? await client.send("steer_subagent", ["sessionId": sessionId, "subagentId": id, "message": text])
        }
    }

    func planAccept() {
        send("Accept the plan and execute it.", mode: .chat, role: "default")
        if var plan = app?.plan {
            plan.state = .executing(step: 1)
            app?.plan = plan
        }
    }

    func planReject() {
        send("Reject the plan. Do not execute anything.", mode: .chat, role: "default")
        if var plan = app?.plan {
            plan.state = .rejected
            app?.plan = plan
        }
    }

    func planRequestRedraft() {
        send("/plan Draft a new plan for the same objective.", mode: .chat, role: "default")
        if var plan = app?.plan {
            plan.state = .refining
            app?.plan = plan
        }
    }

    func planRefine(_ text: String) {
        send("Refine the plan: \(text)", mode: .chat, role: "default")
        if var plan = app?.plan {
            plan.state = .refining
            app?.plan = plan
        }
    }

    func branch(fromEntry: ChatItem) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            guard let entryId = fromEntry.entryId else {
                app.append(.notice("branching needs a synced entry id — try a recent turn"))
                return
            }
            do {
                try await client.send("branch", ["sessionId": sessionId, "entryId": entryId])
                app.append(.steer("⑂ branched from turn \(fromEntry.turn) · this session untouched"))
            } catch {
                app.append(.notice("branch failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func diffVerdict(approved: Bool, note: String?) {
        if approved {
            send("review: looks good — continue", mode: .chat, role: "default")
        } else {
            send("review: \(note ?? "requesting changes")", mode: .chat, role: "default")
        }
    }

    func cycleThinking(role: String) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            guard let idx = app.roles.firstIndex(where: { $0.name == role }) else { return }
            let next = app.roles[idx].thinking.next
            app.roles[idx].thinking = next
            try? await client.send("set_role", ["role": role, "thinkingLevel": next.rawValue])
        }
    }

    func setApprovalMode(_ mode: ApprovalModeSetting) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            app.approvalMode = mode
            try? await client.send("set_approval_mode", ["mode": mode.rawValue])
        }
    }

    func toggleHindsight() {
        app?.hindsightEnabled.toggle()
    }

    func goalPause() {
        guard let app, var goal = app.goal else { return }
        goal.active = false
        app.goal = goal
        send("Pause the goal loop.", mode: .chat, role: "default")
    }

    func goalDrop() {
        app?.goal = nil
        send("Drop the goal.", mode: .chat, role: "default")
    }

    func wakeMachine(id: String) {
        // Wake-on-LAN relaying is a bridge roadmap item; nothing to do yet.
    }

    func searchSessions(_ query: String) async -> [SessionSummary] {
        guard let client else { return [] }
        guard let data = try? await client.send("search_sessions", ["query": query]) else { return [] }
        return (data["sessions"]?.arrayValue ?? []).compactMap(sessionSummary)
    }

    func createProject(name: String) {
        Task { [weak self] in
            guard let client = self?.client else { return }
            _ = try? await client.send("create_project", ["name": name])
            self?.refreshSessions()
        }
    }

    func deleteProject(id: String) {
        Task { [weak self] in
            guard let client = self?.client else { return }
            _ = try? await client.send("delete_project", ["projectId": id])
            self?.refreshSessions()
        }
    }

    func moveCwd(_ cwd: String, toProject projectId: String?) {
        Task { [weak self] in
            guard let client = self?.client else { return }
            var payload: [String: Any] = ["cwd": cwd]
            if let projectId { payload["projectId"] = projectId }
            _ = try? await client.send("assign_cwd", payload)
            self?.refreshSessions()
        }
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
