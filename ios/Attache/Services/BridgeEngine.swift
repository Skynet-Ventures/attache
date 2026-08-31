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
    /// What we're attached to, for automatic re-attach after reconnects.
    private var currentSummary: SessionSummary?
    private var lastSeq: Int = 0
    private var reloadingAfterGap = false
    /// History can't be paged while omp is streaming (session_busy) — when a
    /// reload is needed mid-turn, defer it until the turn settles.
    private var needsReloadAfterTurn = false

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
                Task {
                    await self.handshake()
                    await self.reattachIfNeeded()
                }
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
            if let models = hello["enabledModels"]?.arrayValue {
                app.enabledModels = models.compactMap(\.stringValue)
            }
            // Keep the bridge's push registration in sync with local settings.
            if !app.webhookURL.isEmpty {
                _ = try? await client.send("register_push", ["transport": "webhook", "target": app.webhookURL])
            }
            // Real environment values for the settings screen.
            if let summary = try? await client.send("get_omp_summary") {
                let mcp = summary["mcpServers"]?.intValue ?? 0
                app.mcpSummary = mcp == 0 ? "none configured" : "\(mcp) configured"
                let skills = summary["skills"]?.intValue ?? 0
                let extensions = summary["extensions"]?.intValue ?? 0
                app.skillsSummary = "\(skills) · \(extensions)"
                if let snap = summary["snapcompact"] {
                    let pct = Int((snap["threshold"]?.doubleValue ?? 0.85) * 100)
                    app.snapcompactLabel = (snap["enabled"]?.boolValue ?? true) ? "auto @ \(pct)%" : "off"
                }
                if let fallbacks = summary["fallbacks"]?.objectValue,
                   let chain = fallbacks["default"]?.arrayValue ?? fallbacks.values.first?.arrayValue {
                    app.fallbackChain = chain.compactMap {
                        $0.stringValue?.split(separator: "/").last.map(String.init)
                    }
                } else {
                    app.fallbackChain = []
                }
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
        return RoleModel(name: name, model: shortModel, fullModel: model, thinking: level)
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
            self.currentSummary = summary
            self.lastSeq = 0
            self.toolItems = [:]
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

    /// After a reconnect the new socket has no session subscriptions: re-attach
    /// to whatever the user had open and rebuild the transcript. If the bridge
    /// restarted (old session id gone), fall back to resuming by session path.
    private func reattachIfNeeded() async {
        guard let client, let app, let summary = currentSummary else { return }
        let previousId = app.sessionId
        // Never fall back to a bare/empty cwd attach — that would silently
        // create a brand-new session in $HOME instead of resuming.
        guard previousId != nil || !summary.sessionPath.isEmpty || !summary.cwd.isEmpty else { return }
        do {
            var payload: [String: Any] = [:]
            if let previousId {
                payload["sessionId"] = previousId
            } else if !summary.sessionPath.isEmpty {
                payload["sessionPath"] = summary.sessionPath
                payload["cwd"] = summary.cwd
            } else {
                payload["cwd"] = summary.cwd
            }
            let result = try await client.send("attach", payload)
            app.sessionId = result["sessionId"]?.stringValue
        } catch {
            // Old id is stale (bridge restarted): resume the stored session.
            guard !summary.sessionPath.isEmpty else { return }
            guard let result = try? await client.send("attach", [
                "sessionPath": summary.sessionPath, "cwd": summary.cwd,
            ]) else { return }
            app.sessionId = result["sessionId"]?.stringValue
        }
        lastSeq = 0
        await reloadTranscript()
        refreshSubagents()
    }

    /// Full transcript rebuild — used after reconnects and seq gaps.
    ///
    /// The existing transcript is NEVER cleared until replacement content has
    /// actually arrived: omp rejects history paging while streaming
    /// (session_busy), and blanking the screen on that failure was a bug.
    private func reloadTranscript() async {
        guard let app else { return }
        guard let staged = await fetchHistoryItems() else {
            // Busy or disconnected — keep what we have, retry after the turn.
            needsReloadAfterTurn = true
            return
        }
        var items = staged
        // Re-append any still-pending approvals so they stay answerable inline.
        for approval in app.approvals where approval.status == .pending && approval.sessionId == app.sessionId {
            items.append(ChatItem(kind: .approval(approval), turn: app.turnNo))
        }
        app.items = items
        toolItems = [:]
        streamingItemId = nil
    }

    private func loadHistory() async {
        await reloadTranscript()
    }

    /// Fetch and convert the full history, or nil if any page failed.
    private func fetchHistoryItems() async -> [ChatItem]? {
        guard let client, let app, let sessionId = app.sessionId else { return nil }
        var items: [ChatItem] = []
        var toolMap: [String: String] = [:]
        var cursor: String?
        var pages = 0
        repeat {
            var payload: [String: Any] = ["sessionId": sessionId, "limit": 256]
            if let cursor { payload["cursor"] = cursor }
            guard let data = try? await client.send("get_messages", payload) else { return nil }
            for message in data["messages"]?.arrayValue ?? [] {
                appendHistoryMessage(message, into: &items, toolMap: &toolMap)
            }
            cursor = data["nextCursor"]?.stringValue
            pages += 1
        } while cursor != nil && pages < 40
        return items
    }

    private func appendHistoryMessage(
        _ value: JSONValue, into items: inout [ChatItem], toolMap: inout [String: String]
    ) {
        let message = value["message"] ?? value
        let role = message["role"]?.stringValue ?? ""
        let blocks = message["content"]?.arrayValue ?? []

        // Tool results arrive as their own messages; fold them into the card.
        if role == "toolResult" || role == "tool" {
            let callId = message["toolCallId"]?.stringValue ?? value["toolCallId"]?.stringValue
            let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            let isError = message["isError"]?.boolValue ?? false
            Self.applyHistoryToolResult(callId: callId, output: text, isError: isError, items: &items, toolMap: toolMap)
            return
        }

        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                guard var text = block["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                if role == "user" {
                    if let advisory = extractAdvisory(text) {
                        items.append(ChatItem(kind: .advisor(advisory)))
                    } else if text.hasPrefix("[steer") || text.hasPrefix("steer:") {
                        items.append(ChatItem(kind: .steer(text)))
                    } else {
                        text = String(text.prefix(4000))
                        items.append(ChatItem(kind: .user(text)))
                    }
                } else if role == "assistant" {
                    items.append(ChatItem(kind: .agentText(String(text.prefix(8000)))))
                }
            case "toolCall", "tool_call", "toolUse":
                let name = block["name"]?.stringValue ?? block["toolName"]?.stringValue ?? "tool"
                let item = ChatItem(
                    kind: .toolCard(toolCard(name: name, args: block["arguments"] ?? block["input"], result: nil))
                )
                items.append(item)
                if let callId = block["id"]?.stringValue ?? block["toolCallId"]?.stringValue {
                    toolMap[callId] = item.id
                }
            case "toolResult", "tool_result":
                let callId = block["toolCallId"]?.stringValue ?? block["id"]?.stringValue
                let text = block["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                    ?? block["text"]?.stringValue ?? ""
                Self.applyHistoryToolResult(
                    callId: callId, output: text,
                    isError: block["isError"]?.boolValue ?? false,
                    items: &items, toolMap: toolMap
                )
            default:
                continue
            }
        }
    }

    /// Attach output preview + status to a previously converted tool card.
    private static func applyHistoryToolResult(
        callId: String?, output: String, isError: Bool,
        items: inout [ChatItem], toolMap: [String: String]
    ) {
        let itemId = callId.flatMap { toolMap[$0] } ?? items.last(where: {
            if case .toolCard(let t) = $0.kind { return t.meta.isEmpty && t.detailLines.isEmpty }
            return false
        })?.id
        guard let itemId,
              let idx = items.firstIndex(where: { $0.id == itemId }),
              case .toolCard(var card) = items[idx].kind else { return }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        if card.meta.isEmpty {
            card.meta = isError ? "✕ error" : String((lines.first ?? "done").prefix(28))
        }
        if card.detailLines.isEmpty, lines.count > 1 {
            card.detailLines = lines.prefix(8).map {
                DiffLine(kind: .context, text: String($0.prefix(90)))
            }
            if lines.count > 8 {
                card.detailLines.append(DiffLine(kind: .context, text: "+ \(lines.count - 8) more lines"))
            }
        }
        applyDiffIfPresent(&card, output: output)
        items[idx].kind = .toolCard(card)
    }

    /// If a tool result reads like a unified diff (omp's edit/write results
    /// do), convert it into typed diff lines so the card gets ±counts and the
    /// full-screen "review ▸" flow.
    static func applyDiffIfPresent(_ card: inout ToolCardModel, output: String) {
        guard ["edit", "write", "ast_edit"].contains(card.verb) || output.contains("@@") else { return }
        let rawLines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var diffLines: [DiffLine] = []
        var adds = 0
        var dels = 0
        var sawMarker = false
        for raw in rawLines.prefix(400) {
            let line = String(raw.prefix(160))
            // omp edit results prefix lines with hashline ids like "a3f2| + code".
            let stripped = line.replacingOccurrences(
                of: #"^\s*[0-9a-f]{2,8}\s*\|\s?"#, with: "", options: .regularExpression
            )
            if stripped.hasPrefix("@@") {
                diffLines.append(DiffLine(kind: .hunk, text: stripped)); sawMarker = true
            } else if stripped.hasPrefix("+"), !stripped.hasPrefix("+++") {
                diffLines.append(DiffLine(kind: .add, text: stripped)); adds += 1; sawMarker = true
            } else if stripped.hasPrefix("-"), !stripped.hasPrefix("---") {
                diffLines.append(DiffLine(kind: .del, text: stripped)); dels += 1; sawMarker = true
            } else {
                diffLines.append(DiffLine(kind: .context, text: stripped))
            }
        }
        guard sawMarker, adds + dels > 0 else { return }
        card.detailLines = diffLines
        card.addCount = adds
        card.delCount = dels
        if card.footer == nil { card.footer = "" }
    }

    // MARK: Event handling

    private func handleEvent(type: String, frame: JSONValue) {
        guard let app else { return }
        switch type {
        case "session_state":
            applyState(frame["state"])
        case "stream":
            guard frame["sessionId"]?.stringValue == app.sessionId else { return }
            if let seq = frame["seq"]?.intValue {
                if lastSeq > 0, seq > lastSeq + 1 {
                    // Missed events (reconnect race). Mid-turn, omp refuses
                    // history paging, so defer the rebuild until the turn
                    // settles; either way keep rendering this event.
                    if app.turnActive || app.typing {
                        needsReloadAfterTurn = true
                    } else if !reloadingAfterGap {
                        reloadingAfterGap = true
                        Task { [weak self] in
                            await self?.reloadTranscript()
                            self?.reloadingAfterGap = false
                        }
                    }
                }
                lastSeq = max(lastSeq, seq)
            }
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
        applyPlanFromTodos(state["todoPhases"])
    }

    /// omp's plan-of-record is its todo phase list (plan mode seeds it, and
    /// the agent updates task status as it executes). Mirror it into the plan
    /// screen so live sessions get the same review surface as the demo.
    private func applyPlanFromTodos(_ phases: JSONValue?) {
        guard let app else { return }
        let allTasks: [(phase: String, content: String, status: String)] = (phases?.arrayValue ?? []).flatMap { phase in
            (phase["tasks"]?.arrayValue ?? []).compactMap { task in
                guard let content = task["content"]?.stringValue else { return nil }
                return (
                    phase: phase["name"]?.stringValue ?? "Plan",
                    content: content,
                    status: task["status"]?.stringValue ?? "pending"
                )
            }
        }
        guard !allTasks.isEmpty else {
            if app.plan != nil { app.plan = nil }
            return
        }
        let steps = allTasks.map { task in
            PlanStepModel(
                title: task.content,
                file: task.phase,
                risk: .low,
                mark: task.status == "completed" ? .done : task.status == "in_progress" ? .active : .pending
            )
        }
        let doneCount = steps.filter { $0.mark == .done }.count
        let activeIdx = steps.firstIndex { $0.mark == .active }
        let state: PlanModel.State =
            activeIdx != nil ? .executing(step: activeIdx! + 1)
            : doneCount == steps.count ? .executing(step: steps.count)
            : doneCount > 0 ? .executing(step: doneCount + 1)
            : .ready
        app.plan = PlanModel(
            title: app.sessionTitle.isEmpty ? "Plan" : app.sessionTitle,
            project: currentSummary?.project ?? "",
            roleLabel: "\(currentSummary?.project ?? "") · \(app.modelLabel) · \(doneCount)/\(steps.count) done",
            summary: "Live todo list from omp — \(steps.count) steps. Accept/refine below steer the agent; step marks update as it works.",
            steps: steps,
            state: state
        )
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
                if needsReloadAfterTurn {
                    needsReloadAfterTurn = false
                    Task { [weak self] in await self?.reloadTranscript() }
                }
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
            let resultText = event["result"]?["content"]?.arrayValue?
                .compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? ""
            Self.applyDiffIfPresent(&card, output: resultText)
            app.items[idx].kind = .toolCard(card)
        case "session_exited":
            app.append(.notice("session process ended on \(app.machine.name)"))
            app.turnActive = false
            app.typing = false
        case "extension_ui_request":
            handleUIRequest(event)
        default:
            break
        }
    }

    /// Non-approval extension dialogs (omp's `ask` tool, extension prompts):
    /// render an answerable card so the agent never hangs on us.
    private func handleUIRequest(_ event: JSONValue) {
        guard let app, let id = event["id"]?.stringValue else { return }
        switch event["method"]?.stringValue {
        case "select", "confirm", "input":
            let method = DialogModel.Method(rawValue: event["method"]!.stringValue!) ?? .confirm
            let dialog = DialogModel(
                id: id,
                method: method,
                title: event["title"]?.stringValue ?? "omp is asking",
                message: event["message"]?.stringValue,
                options: event["options"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                placeholder: event["placeholder"]?.stringValue
            )
            app.items.append(ChatItem(kind: .dialog(dialog), turn: app.turnNo))
            NotificationManager.shared.notifyAdvisor(sessionTitle: "\(app.sessionTitle) · needs input")
        case "cancel":
            // A previously asked dialog was withdrawn.
            if let target = event["targetId"]?.stringValue ?? event["id"]?.stringValue {
                markDialog(requestId: target) { $0.cancelled = true }
            }
        case "notify":
            if let message = event["message"]?.stringValue {
                app.append(.notice(message))
            }
        default:
            break
        }
    }

    private func markDialog(requestId: String, _ mutate: (inout DialogModel) -> Void) {
        guard let app else { return }
        guard let idx = app.items.firstIndex(where: {
            if case .dialog(let d) = $0.kind { return d.id == requestId }
            return false
        }), case .dialog(var dialog) = app.items[idx].kind else { return }
        mutate(&dialog)
        app.items[idx].kind = .dialog(dialog)
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

    func send(_ text: String, mode: ComposerMode, role: String, attachments: [ComposerAttachment] = []) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty || !attachments.isEmpty else { return }
            if app.offline {
                app.append(.steer("queued: \"\(trimmed)\" — sends when \(app.machine.name) reconnects"))
                return
            }
            let images = attachments.filter { $0.kind == .image }
            let files = attachments.filter { $0.kind == .file }
            let prefix = mode == .chat ? "" : "[\(mode.rawValue.lowercased())] "
            let attachNote = attachments.isEmpty ? "" : " 📎\(attachments.count)"
            app.append(.user(prefix + trimmed + attachNote))
            if mode == .goal {
                app.goal = GoalModel(objective: trimmed, turns: 1, budget: 40, active: true)
            }
            do {
                // Upload plain files into the session cwd first, then reference
                // their paths in the prompt so the agent can read them.
                var uploadedPaths: [String] = []
                for file in files {
                    let result = try await client.send("upload_file", [
                        "sessionId": sessionId,
                        "name": file.name,
                        "data": file.data.base64EncodedString(),
                    ])
                    if let path = result["path"]?.stringValue { uploadedPaths.append(path) }
                }
                var message = trimmed.isEmpty ? "See the attached content." : trimmed
                if !uploadedPaths.isEmpty {
                    message += "\n\nAttached files (saved on \(app.machine.name)):\n"
                        + uploadedPaths.map { "- \($0)" }.joined(separator: "\n")
                }
                var payload: [String: Any] = [
                    "sessionId": sessionId,
                    "message": message,
                    "mode": mode.rawValue.lowercased(),
                ]
                if app.turnActive { payload["streamingBehavior"] = "steer" }
                if !images.isEmpty {
                    payload["images"] = images.map {
                        ["data": $0.data.base64EncodedString(), "mimeType": $0.mimeType]
                    }
                }
                try await client.send("prompt", payload)
            } catch {
                app.append(.notice("send failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func dispatchSubagent(task: String) {
        send("Dispatch a subagent (task tool) for: \(task)", mode: .chat, role: app?.composerRole ?? "default")
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

    func branchPoints() async -> [BranchPoint] {
        guard let client, let sessionId = app?.sessionId else { return [] }
        guard let data = try? await client.send("get_entries", ["sessionId": sessionId]) else { return [] }
        let entries = (data["entries"]?.arrayValue ?? []).compactMap { entry -> BranchPoint? in
            guard let id = entry["id"]?.stringValue, let role = entry["role"]?.stringValue else { return nil }
            return BranchPoint(id: id, role: role, preview: entry["preview"]?.stringValue ?? "")
        }
        // Newest user turns first — those are the natural fork points.
        return entries.filter { $0.role == "user" }.reversed()
    }

    func branch(entryId: String, preview: String) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            do {
                try await client.send("branch", ["sessionId": sessionId, "entryId": entryId])
                app.append(.steer("⑂ branched before \"\(String(preview.prefix(48)))\" · original untouched"))
                await self.reloadTranscript()
            } catch {
                app.append(.notice("branch failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func answerDialog(itemId: String, value: String?, confirmed: Bool?) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            guard let idx = app.items.firstIndex(where: { $0.id == itemId }),
                  case .dialog(var dialog) = app.items[idx].kind else { return }
            var payload: [String: Any] = ["sessionId": sessionId, "requestId": dialog.id]
            if let value { payload["value"] = value }
            if let confirmed { payload["confirmed"] = confirmed }
            try? await client.send("ui_response", payload)
            dialog.answered = value ?? (confirmed == true ? "yes" : "no")
            app.items[idx].kind = .dialog(dialog)
        }
    }

    func pickRole(_ role: String) {
        guard let app else { return }
        app.composerRole = role
        guard let roleModel = app.roles.first(where: { $0.name == role }), !roleModel.fullModel.isEmpty else { return }
        setModel(roleModel.fullModel)
        Task { [weak self] in
            guard let self, let client = self.client, let sessionId = self.app?.sessionId else { return }
            try? await client.send("set_thinking_level", [
                "sessionId": sessionId, "level": roleModel.thinking.rawValue,
            ])
        }
    }

    func setModel(_ fullModel: String) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app,
                  let sessionId = app.sessionId else { return }
            let selector = fullModel.replacingOccurrences(
                of: ":(off|minimal|low|medium|high|xhigh|max)$", with: "", options: .regularExpression
            )
            let parts = selector.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return }
            do {
                try await client.send("set_model", [
                    "sessionId": sessionId, "provider": String(parts[0]), "modelId": String(parts[1]),
                ])
                app.append(.steer("model → \(parts[1])"))
            } catch {
                app.append(.notice("model switch failed: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func listRules() async -> [AlwaysRuleModel] {
        guard let client else { return [] }
        guard let data = try? await client.send("list_rules") else { return [] }
        return (data["rules"]?.arrayValue ?? []).compactMap { rule in
            guard let id = rule["id"]?.stringValue else { return nil }
            return AlwaysRuleModel(
                id: id,
                tool: rule["tool"]?.stringValue ?? "tool",
                pattern: rule["pattern"]?.stringValue,
                note: rule["note"]?.stringValue ?? "",
                createdAt: rule["createdAt"]?.stringValue ?? ""
            )
        }
    }

    func deleteRule(id: String) {
        Task { [weak self] in
            _ = try? await self?.client?.send("delete_rule", ["ruleId": id])
        }
    }

    func registerWebhook(_ url: String) async -> Bool {
        guard let client, let app else { return false }
        app.webhookURL = url
        UserDefaults.standard.set(url, forKey: "push.webhook")
        return (try? await client.send("register_push", ["transport": "webhook", "target": url])) != nil
    }

    func testWebhook() async -> Bool {
        guard let client else { return false }
        return (try? await client.send("test_push")) != nil
    }

    func startNewSession(cwd: String?, scratch: Bool) {
        Task { [weak self] in
            guard let self, let client = self.client, let app = self.app else { return }
            app.items = []
            app.subagents = []
            app.plan = nil
            app.sessionTitle = scratch ? "Scratch session" : "New session"
            app.branchLabel = scratch ? "scratch" : (cwd as NSString?)?.lastPathComponent ?? ""
            app.sessionId = nil
            self.lastSeq = 0
            self.toolItems = [:]
            app.path.append(.stream)
            do {
                var payload: [String: Any] = [:]
                if scratch { payload["scratch"] = true } else if let cwd { payload["cwd"] = cwd }
                let result = try await client.send("attach", payload)
                app.sessionId = result["sessionId"]?.stringValue
                self.currentSummary = SessionSummary(
                    id: app.sessionId ?? "", title: app.sessionTitle,
                    project: app.branchLabel, cwd: cwd ?? "",
                    sessionPath: "", updatedAt: Date(), live: true, status: .idle, shortId: ""
                )
                app.append(.notice("fresh session in \(scratch ? "~/scratch" : cwd ?? "?") — say hi"))
                self.refreshSessions()
            } catch {
                app.append(.notice("couldn't start session: \((error as? BridgeError)?.message ?? "error")"))
            }
        }
    }

    func wake(mac: String) async -> Bool {
        guard let client else { return false }
        return (try? await client.send("wake", ["mac": mac])) != nil
    }

    func unpinSession() {
        Task { [weak self] in
            guard let self, let app = self.app else { return }
            if let sessionId = app.sessionId {
                _ = try? await self.client?.send("detach", ["sessionId": sessionId])
            }
            app.sessionId = nil
            app.sessionTitle = ""
            app.items = []
            app.subagents = []
            app.turnActive = false
            app.typing = false
            self.currentSummary = nil
            LiveActivityManager.shared.end()
            self.refreshSessions()
        }
    }

    func stopSession(id: String) {
        Task { [weak self] in
            guard let self, let app = self.app else { return }
            _ = try? await self.client?.send("kill_session", ["sessionId": id])
            if app.sessionId == id {
                self.unpinSession()
            } else {
                self.refreshSessions()
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
