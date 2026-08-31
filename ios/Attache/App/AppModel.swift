import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

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
    case costs
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
    /// A terminal pairing problem: distinct from `offline` (network down,
    /// retrying). `.invalidToken` → re-pair; `.updateRequired` → newer app.
    var pairIssue: PairIssue?
    /// Prompts composed while offline, waiting to flush on reconnect.
    var queuedPromptCount = 0

    // MARK: Active session (stream screen)
    var sessionId: String?
    var sessionTitle = ""
    var branchLabel = ""
    /// The SessionSummary of the session currently being observed. The engine
    /// keeps it in sync (contracts A/B need the parent's sessionPath to spawn
    /// descended sessions).
    var activeSummary: SessionSummary?
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
    /// omp fast mode (snappier turns) for the active session — mirrors the
    /// per-session `fastModeActive` reported by session_state.
    var fastModeActive = false

    // MARK: Queue modes (contract C) — render only; mutated via the session
    // settings sheet and mirrored from session_state.
    var steeringMode: QueueSteeringMode = .all
    var followUpMode: QueueFollowUpMode = .all
    var interruptMode: QueueInterruptMode = .immediate

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
    /// Raw omp todo phases for the stream's collapsible TODO tree.
    var todoPhases: [TodoPhase] = []
    var diff: DiffScreenModel?

    // MARK: Roles & settings
    var roles: [RoleModel] = []
    var enabledModels: [String] = []
    var fallbackChain: [String] = []
    var snapcompactLabel = ""
    var taskIsolationLabel = "none"
    static let isolationModes = ["none", "auto", "apfs", "btrfs", "zfs", "reflink", "overlayfs", "projfs", "block-clone", "rcopy"]
    var webhookURL: String = UserDefaults.standard.string(forKey: "push.webhook") ?? ""
    var approvalMode: ApprovalModeSetting = .write
    var hindsightEnabled = true
    var rulesSummary = ""
    var mcpSummary = ""
    var skillsSummary = ""

    // MARK: Pairing (machines screen)
    var pairedMachines: [PairedMachine] = []

    // MARK: Hub feed & commands
    /// Chronological Comms feed (omp `irc_message` / `notice` / `goal_updated`
    /// stream events) surfaced under the agents screen.
    var hubFeed: [HubMessage] = []
    /// Commands advertised by omp (`available_commands_update` → bridge
    /// `commands` event) for the slash palette.
    var availableCommands: [SlashCommand] = []

    // MARK: Engine
    var engine: (any Engine)?
    private var ticker: Task<Void, Never>?

    var liveAgentCount: Int { subagents.filter { $0.status == .live }.count }

    var elapsedLabel: String {
        "\(elapsedSec / 60)m\(String(format: "%02d", elapsedSec % 60))s"
    }

    /// Battery: this used to tick at 1Hz and mutate `elapsedSec`, invalidating
    /// every observing view each second. The elapsed label now derives itself
    /// in a TimelineView leaf (zero model mutation); this loop only feeds the
    /// change-gated Live Activity / widget mirrors, at 5s, and never while the
    /// app is backgrounded (iOS suspends us anyway — don't burn the wakeups).
    func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                guard UIApplication.shared.applicationState != .background else { continue }
                LiveActivityManager.shared.sync(app: self)
                self.publishWidgetSnapshot()
            }
        }
    }

    // MARK: Home-screen widgets

    /// Mirrors the current state into the shared app group for the home-screen
    /// widgets. Change-detected: a timeline reload only fires when a displayed
    /// value actually moved, so approval/resume updates reach the widget
    /// immediately and idle ticks stay silent.
    func publishWidgetSnapshot() {
        let snapshot = WidgetSnapshot(
            runningSessions: projects.flatMap(\.sessions).filter(\.live).count,
            pendingApprovals: pendingApprovalCount,
            todayCostUSD: costUsd,
            updatedAt: Date(),
            paired: machine != .disconnected
        )
        if WidgetSnapshotStore.publishIfChanged(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Keep widgets safe even if WidgetCenter is unavailable in tests.
    }

    func append(_ kind: ChatItemKind) {
        items.append(ChatItem(kind: kind, turn: turnNo))
    }
}

/// Why the app can no longer talk to the bridge — terminal states that need
/// user action instead of connection retries.
enum PairIssue: Equatable {
    case invalidToken
    case updateRequired
}

struct PairedMachine: Identifiable, Equatable {
    enum State: Equatable { case online(latencyMs: Int), asleep, waking, offline }
    var id: String
    var name: String
    var state: State
    var detail: String     // "tailscale · 12ms · omp 17.3.4 · bun 1.3"
    var sessionsLabel: String
    var canWake: Bool
    /// Wake-on-LAN MAC for this machine; nil when unknown (the paired bridge
    /// machine is awake by definition, WOL targets supply MACs).
    var mac: String?
}

/// User intents. Implemented by DemoEngine (scripted) and BridgeEngine (live).
@MainActor
protocol Engine: AnyObject {
    func start(app: AppModel)
    func refreshSessions()
    func openSession(_ summary: SessionSummary)
    func send(_ text: String, mode: ComposerMode, role: String, attachments: [ComposerAttachment])
    func dispatchSubagent(task: String)
    /// Dispatch requesting an isolated workspace for the worker.
    func dispatchSubagent(task: String, isolated: Bool)
    /// Load an isolated subagent's patch artifact into the diff screen.
    func viewSubagentPatch(id: String)
    /// Write task.isolation.mode to omp's global config.
    func setTaskIsolation(_ mode: String)
    func stopTurn()
    func resolveApproval(id: String, verdict: Verdict)
    /// Resolve an approval with an always-allow scope (contract F). Pass
    /// `.global` (or nil for non-allowAlways verdicts) to keep legacy behavior.
    func resolveApproval(id: String, verdict: Verdict, scope: RuleScopeChoice?)
    func advisorAddress(itemId: String)
    func advisorDismiss(itemId: String)
    func steerSubagent(id: String, text: String)
    func planAccept()
    func planReject()
    func planRequestRedraft()
    func planRefine(_ text: String)
    func branchPoints() async -> [BranchPoint]
    /// Branch points for a STORED session, read directory from its jsonl
    /// (contract G) — no live observation required.
    func branchPoints(for summary: SessionSummary) async -> [BranchPoint]
    func branch(entryId: String, preview: String)
    /// Branch a stored session at an entry: resume it, fork, and land in the
    /// branched session.
    func branchStored(_ summary: SessionSummary, entryId: String, preview: String)
    func answerDialog(itemId: String, value: String?, confirmed: Bool?)
    func pickRole(_ role: String)
    func setModel(_ fullModel: String)
    func listRules() async -> [AlwaysRuleModel]
    func deleteRule(id: String)
    func registerWebhook(_ url: String) async -> Bool
    func testWebhook() async -> Bool
    func startNewSession(cwd: String?, scratch: Bool)
    func wake(mac: String) async -> Bool
    /// Detach from the current session (omp process stays alive on the bridge).
    func unpinSession()
    /// Kill a live session's omp process on the bridge.
    func stopSession(id: String)
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
    /// Rename the active session (bridge `set_session_name`).
    func renameSession(_ name: String)
    /// Fetch per-session stats verbatim from omp (bridge `get_session_stats`).
    func fetchSessionStats() async -> [SessionStatRow]
    /// Toggle omp fast mode for the active session (bridge `set_fast_mode`).
    func setFastMode(_ enabled: Bool)
    /// Remove one persisted offline-queued prompt (swipe-delete in the stream).
    func removeQueuedPrompt(id: String)

    /// Ask the advisor to elaborate on a note: a templated steer quoting the
    /// note's text back to omp. Unlike `advisorAddress` this does not mark the
    /// note addressed — the advisor responds instead of acting.
    func advisorElaborate(itemId: String)

    // MARK: - Post-beta roadmap (contracts A–I)

    /// Hand off the active session (omp `handoff` passthrough). `instructions`
    /// become the handoff's custom instructions when non-nil. Returns the
    /// bridge's verbatim result text.
    func handoff(instructions: String?) async -> HandoffResult

    /// Start a fresh session descended from `parent` (omp `new_session`
    /// with parentSession = the parent's session file path) and attach to it.
    func newSession(parent: SessionSummary, instructions: String?)

    /// Set the session's queue modes (omp set_steering_mode / set_follow_up_mode /
    /// set_interrupt_mode).
    func setQueueModes(
        steeringMode: QueueSteeringMode,
        followUpMode: QueueFollowUpMode,
        interruptMode: QueueInterruptMode
    )

    /// Export the active session transcript (omp `export_html`). Returns the
    /// HTML document base64-encoded. Throws BridgeError(code: "too_large")
    /// when the bridge refuses to move the payload.
    func exportTranscript() async throws -> String

    /// Bridge-side cost aggregation (contract E). `days` defaults to 30.
    func fetchCostSummary(days: Int) async -> CostSummaryModel?

    /// Connect a newly paired machine (contract I). The record is already
    /// persisted by the caller; this wires up its BridgeClient.
    func connectMachine(_ record: PairedMachineRecord)

    /// Disconnect and forget a paired machine (contract I). If it was the
    /// active machine, another machine becomes active.
    func removeMachine(id: String)
}
