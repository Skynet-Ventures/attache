import Foundation
import Observation
import SwiftUI

enum Route: Hashable {
    case stream
    case agents
    case approvals
    case plan
    case diff
    case resume
    case settings
    case machines
    case rules
}

enum OnboardingStage {
    case welcome
    case pairing
    case notifications
    case done
}

/// Root observable state. Engines (demo or bridge) mutate it; views render it.
@Observable @MainActor
final class AppModel {
    // MARK: Navigation
    var path: [Route] = []
    var onboarding: OnboardingStage = .welcome

    // MARK: Machine & sessions
    var machine: MachineStatus = .disconnected
    var projects: [ProjectGroup] = []
    var offline = false

    // MARK: Active session (stream screen)
    var sessionId: String?
    var sessionTitle = ""
    var branchLabel = ""
    var turnNo = 0
    var turnStartedAt: Date?
    var elapsedSec = 0
    var ctxPercent: Double = 0
    var ctxLabel = ""
    var costUsd: Double = 0
    var modelLabel = ""
    var items: [ChatItem] = []
    var typing = false
    var turnActive = false
    var goal: GoalModel?
    var compactNote = "compact@85%"

    // MARK: Composer
    var composerMode: ComposerMode = .chat
    var composerRole = "default"

    // MARK: Approvals (global queue)
    var approvals: [ApprovalModel] = []
    var pendingApprovalCount: Int { approvals.filter { $0.status == .pending }.count }

    // MARK: Subagents
    var subagents: [SubagentModel] = []
    var focusedAgentId: String?
    var focusedAgent: SubagentModel? {
        guard let id = focusedAgentId else { return subagents.first }
        return subagents.first { $0.id == id }
    }

    // MARK: Plan / diff
    var plan: PlanModel?
    var diff: DiffScreenModel?

    // MARK: Roles & settings
    var roles: [RoleModel] = []
    var enabledModels: [String] = []
    var fallbackChain: [String] = []
    var snapcompactLabel = ""
    var webhookURL: String = UserDefaults.standard.string(forKey: "push.webhook") ?? ""
    var approvalMode: ApprovalModeSetting = .write
    var hindsightEnabled = true
    var rulesSummary = ""
    var mcpSummary = ""
    var skillsSummary = ""

    // MARK: Pairing (machines screen)
    var pairedMachines: [PairedMachine] = []

    // MARK: Engine
    var engine: (any Engine)?
    private var ticker: Task<Void, Never>?

    var liveAgentCount: Int { subagents.filter { $0.status == .live }.count }

    var elapsedLabel: String {
        "\(elapsedSec / 60)m\(String(format: "%02d", elapsedSec % 60))s"
    }

    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let start = self.turnStartedAt {
                    self.elapsedSec = Int(-start.timeIntervalSinceNow)
                } else if self.turnActive {
                    self.elapsedSec += 1
                }
                LiveActivityManager.shared.sync(app: self)
            }
        }
    }

    func append(_ kind: ChatItemKind) {
        items.append(ChatItem(kind: kind, turn: turnNo))
    }
}

struct PairedMachine: Identifiable, Equatable {
    enum State: Equatable { case online(latencyMs: Int), asleep, waking, offline }
    var id: String
    var name: String
    var state: State
    var detail: String     // "tailscale · 12ms · omp 17.3.4 · bun 1.3"
    var sessionsLabel: String
    var canWake: Bool
}

/// User intents. Implemented by DemoEngine (scripted) and BridgeEngine (live).
@MainActor
protocol Engine: AnyObject {
    func start(app: AppModel)
    func refreshSessions()
    func openSession(_ summary: SessionSummary)
    func send(_ text: String, mode: ComposerMode, role: String, images: [AttachedImage])
    func dispatchSubagent(task: String)
    func stopTurn()
    func resolveApproval(id: String, verdict: Verdict)
    func advisorAddress(itemId: String)
    func advisorDismiss(itemId: String)
    func steerSubagent(id: String, text: String)
    func planAccept()
    func planReject()
    func planRequestRedraft()
    func planRefine(_ text: String)
    func branchPoints() async -> [BranchPoint]
    func branch(entryId: String, preview: String)
    func answerDialog(itemId: String, value: String?, confirmed: Bool?)
    func pickRole(_ role: String)
    func setModel(_ fullModel: String)
    func listRules() async -> [AlwaysRuleModel]
    func deleteRule(id: String)
    func registerWebhook(_ url: String) async -> Bool
    func testWebhook() async -> Bool
    func startNewSession(cwd: String?, scratch: Bool)
    func wake(mac: String) async -> Bool
    func diffVerdict(approved: Bool, note: String?)
    func cycleThinking(role: String)
    func setApprovalMode(_ mode: ApprovalModeSetting)
    func toggleHindsight()
    func goalPause()
    func goalDrop()
    func wakeMachine(id: String)
    func searchSessions(_ query: String) async -> [SessionSummary]
    func createProject(name: String)
    func deleteProject(id: String)
    func moveCwd(_ cwd: String, toProject projectId: String?)
}
