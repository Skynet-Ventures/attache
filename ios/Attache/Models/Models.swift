import Foundation
import Observation

// MARK: - Enums shared with the bridge protocol

enum ThinkingLevel: String, Codable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
    /// Cycle order used by the roles screen (skips `off`, like the design).
    static let cycle: [ThinkingLevel] = [.minimal, .low, .medium, .high, .xhigh, .max]
    var next: ThinkingLevel {
        guard let idx = Self.cycle.firstIndex(of: self) else { return .minimal }
        return Self.cycle[(idx + 1) % Self.cycle.count]
    }
}

enum ApprovalModeSetting: String, Codable, CaseIterable {
    case yolo
    case write
    case alwaysAsk = "always-ask"
    var label: String {
        switch self {
        case .yolo: "yolo"
        case .write: "ask destr."
        case .alwaysAsk: "ask all"
        }
    }
}

enum ComposerMode: String, CaseIterable {
    case chat = "CHAT", plan = "PLAN", goal = "GOAL", loop = "LOOP"
    var next: ComposerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum Verdict: String, Codable {
    case allow
    case allowAlways = "allow_always"
    case deny
}

enum RiskLevel: String, Codable {
    case high, medium, low
    var label: String {
        switch self {
        case .high: "HIGH"
        case .medium: "MED"
        case .low: "LOW"
        }
    }
}

// MARK: - Machine / connection

enum MachineLink: Equatable {
    case online(latencyMs: Int)
    case connecting
    case offline
    case demo
}

struct MachineStatus: Equatable {
    var name: String
    var link: MachineLink
    var ompVersion: String
    var bridgeVersion: String
    var liveSessionCount: Int

    static let disconnected = MachineStatus(
        name: "no machine", link: .offline, ompVersion: "", bridgeVersion: "", liveSessionCount: 0
    )
}

// MARK: - Sessions list

struct SessionSummary: Identifiable, Equatable {
    enum Status: String { case running, waiting, idle, done }
    var id: String
    var title: String
    var project: String
    var cwd: String
    var sessionPath: String
    var updatedAt: Date
    var live: Bool
    var status: Status
    var shortId: String
    /// Owning paired machine (contract I). Empty for single-machine installs
    /// where all sessions belong to the only paired machine.
    var machineId: String = ""
    var machineName: String = ""
    var ageLabel: String {
        let secs = max(0, -updatedAt.timeIntervalSinceNow)
        if secs < 90 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }
}

struct ProjectGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var cwd: String
    var custom: Bool
    var sessions: [SessionSummary]
    /// Owning paired machine (contract I); empty means the single paired
    /// machine.
    var machineId: String = ""
    var machineName: String = ""
}

// MARK: - Chat stream

struct ToolCardModel: Equatable {
    var icon: String        // "✓", "±", "$", "◇"
    var iconIsAccent: Bool
    var verb: String        // "search", "edit", "bash", ...
    var subject: String     // argument summary
    var meta: String        // "14 hits", "exit 0 · 0.3s"
    var detailLines: [DiffLine]
    var footer: String?     // "lsp ✓ 0 diagnostics · gofmt ok"
    var addCount: Int?
    var delCount: Int?
    var hashline: String?
    var hasDiff: Bool { addCount != nil }
    var running: Bool = false
}

struct DiffLine: Equatable, Identifiable {
    enum Kind { case context, add, del, hunk }
    var id = UUID()
    var kind: Kind
    var text: String
}

struct AdvisorNoteModel: Equatable {
    var advisor: String
    var severity: String
    var text: String
    var modelLabel: String
    var afterTurn: Int
    var state: State = .open
    enum State { case open, dismissed, addressed }
}

struct ApprovalModel: Identifiable, Equatable {
    var id: String
    var sessionId: String
    var sessionTitle: String
    var tool: String
    var risk: RiskLevel
    var riskDetail: String   // "HIGH · BASH"
    var source: String       // "pixeld · 40s ago"
    var command: String?
    var diffLines: [DiffLine]
    var reason: String
    var status: Status = .pending
    var createdAt = Date()
    enum Status: Equatable { case pending, allowed, always, denied }
}

/// A non-approval question from omp or an extension (`ask` tool, dialogs).
struct DialogModel: Identifiable, Equatable {
    enum Method: String { case select, confirm, input }
    var id: String                 // extension_ui_request id
    var method: Method
    var title: String
    var message: String?
    var options: [String]
    var placeholder: String?
    var answered: String? = nil    // chosen option / typed text / "yes"/"no"
    var cancelled = false
}

enum ChatItemKind: Equatable {
    case user(String)
    case agentText(String)
    case thinking(String)
    case steer(String)
    case toolCard(ToolCardModel)
    case advisor(AdvisorNoteModel)
    case approval(ApprovalModel)
    case dialog(DialogModel)
    case queued(QueuedPrompt)
    case notice(String)
}

struct ChatItem: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: ChatItemKind
    /// omp entry id when known — branch targets.
    var entryId: String?
    var turn: Int = 0
}

// MARK: - Subagents

struct SubagentModel: Identifiable, Equatable {
    enum Status: Equatable { case live, done, queued }
    var id: String
    var name: String
    var status: Status
    var lastLine: String
    var meta: String          // "2m14s · 8.1k tok · 12 calls"
    var handle: String        // "agent://b2c9"
    var transcript: [SubagentLine]
}

struct SubagentLine: Identifiable, Equatable {
    enum Kind { case tool, text, steer }
    var id = UUID()
    var kind: Kind
    var text: String
    var meta: String = ""
}

// MARK: - Plan

struct PlanStepModel: Identifiable, Equatable {
    enum Mark: Equatable { case pending, active, done }
    var id = UUID()
    var title: String
    var file: String
    var risk: RiskLevel
    var mark: Mark = .pending
}

struct PlanModel: Equatable {
    enum State: Equatable { case ready, refining, rejected, executing(step: Int) }
    var title: String
    var project: String
    var roleLabel: String     // "plan role · grok-4.5:high"
    var summary: String
    var steps: [PlanStepModel]
    var state: State = .ready
}

// MARK: - Goal

struct GoalModel: Equatable {
    var objective: String
    var turns: Int
    var budget: Int
    var active: Bool
}

// MARK: - Roles / settings

struct RoleModel: Identifiable, Equatable {
    var id: String { name }
    var name: String
    /// Short display name ("GLM-5.3-Flash-EXL3").
    var model: String
    /// Full selector for set_model ("glm-sparks/GLM-5.3-Flash-EXL3").
    var fullModel: String = ""
    var thinking: ThinkingLevel
}

struct AlwaysRuleModel: Identifiable, Equatable {
    var id: String
    var tool: String
    var pattern: String?
    var note: String
    var createdAt: String
    /// Where the rule applies (contract F). Old bridge-side rules created
    /// without a scope decode as global for back-compat.
    var scope: RuleScope = .global
}

struct BranchPoint: Identifiable, Equatable {
    var id: String        // omp entry id
    var role: String
    var preview: String
}

/// Something attached in the composer: photos ride omp's `images` prompt
/// field; other files are uploaded into the session cwd for the agent to read.
struct ComposerAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case image, file }
    var id = UUID()
    var kind: Kind
    var name: String
    var data: Data
    var mimeType: String

    static func image(_ jpeg: Data) -> ComposerAttachment {
        ComposerAttachment(kind: .image, name: "photo.jpg", data: jpeg, mimeType: "image/jpeg")
    }

    static func file(name: String, data: Data) -> ComposerAttachment {
        ComposerAttachment(kind: .file, name: name, data: data, mimeType: "application/octet-stream")
    }
}

// MARK: - Full-screen diff

struct DiffScreenModel: Equatable {
    var fileName: String
    var directory: String
    var addCount: Int
    var delCount: Int
    var hashline: String
    var lines: [DiffLine]
    var footer: String

    /// Per-file collapsible sections for the review surface.
    var sections: [DiffFileSection] { DiffSections.sections(from: lines) }
}

// MARK: - Offline queue

/// A prompt the user sent while the bridge was unreachable. Persisted so a
/// crash or re-launch does not drop it; flushed in FIFO order on reconnect.
struct QueuedImage: Codable, Equatable {
    var data: Data
    var mimeType: String
}

struct QueuedFile: Codable, Equatable {
    var name: String
    var data: Data
}

struct QueuedPrompt: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    /// Lowercased ComposerMode raw value ("chat" | "plan" | "goal" | "loop").
    var mode: String
    var role: String
    var images: [QueuedImage]
    var files: [QueuedFile]
    var createdAt: Date
    /// Session this prompt was composed in — flush only targets the same
    /// session so prompts never land in the wrong transcript.
    var sessionId: String?

    var attachmentCount: Int { images.count + files.count }
    var hasAttachments: Bool { attachmentCount > 0 }

    init(
        id: UUID = UUID(), text: String, mode: String, role: String,
        images: [QueuedImage] = [], files: [QueuedFile] = [],
        createdAt: Date = Date(), sessionId: String?
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.role = role
        self.images = images
        self.files = files
        self.createdAt = createdAt
        self.sessionId = sessionId
    }
}

// MARK: - Session stats

/// One key/value row from the bridge's `get_session_stats` passthrough.
/// omp's stats shape is not under our control — we render it verbatim.
struct SessionStatRow: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var value: String
}

// MARK: - Multi-machine (contract I)

/// Persisted record of one paired machine. The bearer token lives in the
/// Keychain under "bridge.token.<id>"; `pushKey` is the base64 AES-256-GCM
/// key exchanged at pair time for APNs payloads (empty for webhook-only
/// pairings).
struct PairedMachineRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var pushKey: String
}

/// Pure routing helper: given a session, decide which paired machine owns it.
/// Stored sessions carry an explicit machineId; anything else falls back to
/// the active machine (single-machine installs have one machine and always
/// route here). Kept side-effect free so the routing contract is unit-testable.
enum MachineRouter {
    static func owningMachine(
        for session: SessionSummary?,
        activeMachineId: String?,
        paired: [PairedMachineRecord]
    ) -> String? {
        if let session, !session.machineId.isEmpty,
           paired.contains(where: { $0.id == session.machineId }) {
            return session.machineId
        }
        if let activeMachineId, paired.contains(where: { $0.id == activeMachineId }) {
            return activeMachineId
        }
        return paired.first?.id
    }
}

// MARK: - Queue modes (contract C)

/// omp queue steering modes. Raw values must match the omp RPC surface
/// (`set_steering_mode` / `set_follow_up_mode` / `set_interrupt_mode`).
enum QueueSteeringMode: String, CaseIterable, Identifiable {
    case all
    case oneAtATime = "one-at-a-time"
    var id: String { rawValue }
    var label: String { self == .all ? "All at once" : "One at a time" }
}

enum QueueFollowUpMode: String, CaseIterable, Identifiable {
    case all
    case oneAtATime = "one-at-a-time"
    var id: String { rawValue }
    var label: String { self == .all ? "All at once" : "One at a time" }
}

enum QueueInterruptMode: String, CaseIterable, Identifiable {
    case immediate
    case wait
    var id: String { rawValue }
    var label: String { self == .immediate ? "Interrupt immediately" : "Wait for turn end" }
}

// MARK: - Rule scoping (contract F)

enum RuleScopeKind: String, Codable, Equatable {
    case global, cwd, session
}

/// Where an always-allow rule applies. Matches the bridge rules.json shape:
/// `{ kind: "global" } | { kind: "cwd", cwd } | { kind: "session", sessionId }`.
struct RuleScope: Codable, Equatable {
    var kind: RuleScopeKind
    var cwd: String?
    var sessionId: String?

    static let global = RuleScope(kind: .global, cwd: nil, sessionId: nil)
}

/// What the user picked in the always-allow scope picker. The engine resolves
/// the concrete cwd/sessionId from session context ("This project"/"This
/// session" are meaningless without it).
enum RuleScopeChoice: String, CaseIterable, Identifiable {
    case global, thisSession, thisProject
    var id: String { rawValue }
    var label: String {
        switch self {
        case .global: "Everywhere"
        case .thisSession: "This session"
        case .thisProject: "This project"
        }
    }
    var caption: String {
        switch self {
        case .global: "rule applies on every machine and project"
        case .thisSession: "only while this exact session runs"
        case .thisProject: "for tools running inside this project"
        }
    }
}

// MARK: - Cost dashboard (contract E)

struct CostDay: Identifiable, Equatable {
    var date: String        // "2026-08-30"
    var costUSD: Double
    var tokensIn: Int
    var tokensOut: Int
    var sessions: Int
    var id: String { date }
}

struct CostProjectRow: Identifiable, Equatable {
    var projectId: String?
    var cwd: String
    var costUSD: Double
    var sessions: Int
    var id: String { projectId ?? cwd }
}

/// Bridge-side aggregation over the session index (contract E). Shape mirrors
/// the payload: `{ days: [...], byProject: [...] }`.
struct CostSummaryModel: Equatable {
    var days: [CostDay]
    var byProject: [CostProjectRow]
}

// MARK: - Handoff / new-session-from-parent (contracts A & B)

/// Result of a handoff request. `detail` is the bridge's verbatim response
/// text (e.g. the handoff file path); nil on network failure.
struct HandoffResult: Equatable {
    var detail: String?
    var error: String?
}

// MARK: - Commands (slash palette)

/// A command omp advertises via `available_commands_update`, forwarded by the
/// bridge as a `commands` event and stored in session state. The palette
/// renders these verbatim; descriptions/hints come straight from omp.
struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var source: String
    var aliases: [String] = []
    /// `description` from omp (short help line shown in the palette).
    var summary: String?
    /// `input.hint` from omp ("<prompt>" argument slot guidance).
    var hint: String?
    var subcommands: [SlashCommand] = []
}

// MARK: - Hub feed

/// One entry in the Comms feed. Built from omp `irc_message` / `notice` /
/// `goal_updated` stream events; chronological and never edited in place.
struct HubMessage: Identifiable, Equatable {
    enum Kind: Equatable { case message, notice, goal }
    var id = UUID()
    var kind: Kind
    var sender: String?
    var text: String
    /// `notice` level from omp ("info" | "warning" | "error").
    var level: String?
    /// `goal_updated` objective, so goal changes can be highlighted distinctly.
    var goalObjective: String?
    var goalStatus: String?
    var timestamp = Date()
}

// MARK: - Diff review sections

/// A file-level chunk of a parsed unified diff. Used to render per-file
/// collapsible review sections instead of one flat blob.
struct DiffFileSection: Identifiable, Equatable {
    var id = UUID()
    var path: String
    var lines: [DiffLine]
    var addCount: Int
    var delCount: Int
}

/// Splits parsed diff lines into per-file sections at diff headers
/// (`diff --git`, `Index:`, `--- `/`+++ ` path pairs, `===`, `***`).
enum DiffSections {
    /// Parses diff lines into ordered per-file sections. Lines before any
    /// header (or with no header at all) land in a single "(diff)" section so
    /// the reviewer still sees every add/del.
    static func sections(from lines: [DiffLine]) -> [DiffFileSection] {
        var result: [DiffFileSection] = []
        var path: String?
        var current: [DiffLine] = []
        var adds = 0
        var dels = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(DiffFileSection(
                path: path ?? "(diff)", lines: current, addCount: adds, delCount: dels
            ))
            path = nil
            current = []
            adds = 0
            dels = 0
        }

        for line in lines {
            let text = line.text
            if let newPath = headerPath(text) {
                flush()
                path = newPath
                continue
            }
            // A `--- `/`+++ ` pair immediately after a section start supplies
            // the path when no `diff --git`/`Index:` header preceded it.
            if path == nil, current.isEmpty, isPathPair(text), let p = pathFromPair(text) {
                path = p
                continue
            }
            switch line.kind {
            case .add: adds += 1
            case .del: dels += 1
            case .context, .hunk: break
            }
            current.append(line)
        }
        flush()
        return result
    }

    /// Returns a file path when `text` opens a new file section, else nil.
    static func headerPath(_ text: String) -> String? {
        if text.hasPrefix("diff --git ") {
            // "diff --git a/x b/y" → strip optional a/ prefix off the second path.
            let rest = text.dropFirst("diff --git ".count)
            let parts = rest.components(separatedBy: " b/")
            if parts.count >= 2 {
                let path = parts.last!
                    .split(separator: "\t").first.map(String.init) ?? ""
                return Self.normalize(path)
            }
            return "(diff)"
        }
        if text.hasPrefix("Index: ") || text.hasPrefix("===") || text.hasPrefix("*** ") {
            return "(diff)"
        }
        return nil
    }

    /// True when the line is a `--- path` / `+++ path` file header (as opposed
    /// to a deleted/added content line).
    static func isPathPair(_ text: String) -> Bool {
        text.hasPrefix("--- ") || text.hasPrefix("+++ ")
    }

    static func pathFromPair(_ text: String) -> String? {
        let rest = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return Self.normalize(rest)
    }

    /// Strips a/ and b/ prefixes and the timestamp column.
    static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("\"") { p.removeFirst() }
        if p.hasSuffix("\"") { p.removeLast() }
        for prefix in ["a/", "b/"] where p.hasPrefix(prefix) {
            p.removeFirst(prefix.count)
        }
        if let tab = p.firstIndex(of: "\t") { p = String(p[p.startIndex..<tab]) }
        return p.isEmpty ? "(diff)" : p
    }
}

// MARK: - Stream tool-run grouping

/// A consecutive run of completed tool cards is folded into one collapsible
/// row once it reaches `collapseThreshold`. Streaming (in-flight) tools are
/// never folded — they must stay visible while they run, so they break runs
/// on both sides.
enum StreamGrouping {
    static let collapseThreshold = 3

    /// Maps the live item list to render units. Consecutive non-running tool
    /// cards at or above `collapseThreshold` become one `.toolRun`; shorter
    /// runs and every other item pass through as-is.
    static func renderUnits(from items: [ChatItem]) -> [StreamRenderUnit] {
        var units: [StreamRenderUnit] = []
        var run: [ChatItem] = []
        for item in items {
            if case .toolCard(let tool) = item.kind, !tool.running {
                run.append(item)
            } else {
                appendRun(run, to: &units)
                run = []
                units.append(.item(item))
            }
        }
        appendRun(run, to: &units)
        return units
    }

    private static func appendRun(_ run: [ChatItem], to units: inout [StreamRenderUnit]) {
        if run.count >= collapseThreshold {
            units.append(.toolRun(ToolRunGroup(id: run[0].id, tools: run.compactMap {
                if case .toolCard(let tool) = $0.kind { return tool }
                return nil
            })))
        } else {
            units.append(contentsOf: run.map { .item($0) })
        }
    }
}

/// What the stream actually renders: an individual item, or a folded run of
/// completed tool cards.
enum StreamRenderUnit: Identifiable, Equatable {
    case item(ChatItem)
    case toolRun(ToolRunGroup)

    var id: String {
        switch self {
        case .item(let item): item.id
        case .toolRun(let group): group.id
        }
    }
}

/// A consecutive run of completed tool calls, foldable into one row.
struct ToolRunGroup: Identifiable, Equatable {
    var id: String
    var tools: [ToolCardModel]
    var toolCount: Int { tools.count }
}
