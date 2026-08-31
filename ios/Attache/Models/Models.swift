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

enum ChatItemKind: Equatable {
    case user(String)
    case agentText(String)
    case thinking(String)
    case steer(String)
    case toolCard(ToolCardModel)
    case advisor(AdvisorNoteModel)
    case approval(ApprovalModel)
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
    var model: String
    var thinking: ThinkingLevel
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
}
