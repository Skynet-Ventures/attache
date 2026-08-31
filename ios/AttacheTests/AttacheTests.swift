import Foundation
import Testing
@testable import Attache

struct ThinkingLevelTests {
    @Test func cycleWraps() {
        #expect(ThinkingLevel.minimal.next == .low)
        #expect(ThinkingLevel.max.next == .minimal)
        #expect(ThinkingLevel.off.next == .minimal)
    }
}

struct SessionSummaryTests {
    @Test func ageLabels() {
        let now = SessionSummary(
            id: "1", title: "t", project: "p", cwd: "/", sessionPath: "",
            updatedAt: .now, live: false, status: .idle, shortId: "#1"
        )
        #expect(now.ageLabel == "now")
        var older = now
        older.updatedAt = .now.addingTimeInterval(-3 * 3600)
        #expect(older.ageLabel == "3h")
        older.updatedAt = .now.addingTimeInterval(-2 * 86_400)
        #expect(older.ageLabel == "2d")
    }
}

struct JSONValueTests {
    @Test func decodesNested() throws {
        let data = Data(#"{"a":{"b":[1,"x",true]},"n":null}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["a"]?["b"]?.arrayValue?.count == 3)
        #expect(value["a"]?["b"]?.arrayValue?.first?.intValue == 1)
        #expect(value["n"] == .null)
    }
}

// MARK: - APNs crypto (contract H)

/// Asserts that `body` throws — kept macro-independent so the round-trip
/// test stays valid across Swift Testing versions.
private func expectThrows(_ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected the call to throw")
    } catch {
        // Success: an error was thrown.
    }
}

struct APNSCryptoTests {
    @Test func decryptRoundTripsThroughBridgeFrame() throws {
        // The app/bridge encrypts with the paired pushKey; the notification
        // service extension must open exactly that frame format.
        let key = APNSCrypto.makeKey()
        let message = PushMessageContent(
            kind: "approval", title: "Approval · bash",
            body: "rm -rf build", sessionId: "sess-1", approvalId: "appr-9", host: "100.64.0.2:8674"
        )
        let frame = try APNSCrypto.encrypt(message, key: key)
        let opened = try APNSCrypto.decrypt(payload: frame, key: key)
        #expect(opened == message)
        // A tampered frame must fail, not corrupt silently.
        var bytes = Data(frame.utf8)
        bytes[bytes.count - 3] = bytes[bytes.count - 3] == 0x41 ? 0x42 : 0x41
        let tampered = String(data: bytes, encoding: .utf8)!
        expectThrows {
            try APNSCrypto.decrypt(payload: tampered, key: key)
        }
    }

    @Test func wrongKeyFailsToOpen() throws {
        let message = PushMessageContent(kind: "turn_done", title: "t", body: "b", sessionId: "s")
        let frame = try APNSCrypto.encrypt(message, key: APNSCrypto.makeKey())
        expectThrows {
            try APNSCrypto.decrypt(payload: frame, key: APNSCrypto.makeKey())
        }
    }

    @Test func shortFrameIsRejected() {
        expectThrows {
            try APNSCrypto.decrypt(payload: "AQID", key: APNSCrypto.makeKey())
        }
    }
}

// MARK: - Home-screen widget snapshot

struct WidgetSnapshotTests {
    @Test func codecRoundTrips() throws {
        var snapshot = WidgetSnapshot(
            runningSessions: 2, pendingApprovals: 1, todayCostUSD: 4.20,
            updatedAt: .now, paired: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        snapshot.updatedAt = decoded.updatedAt
        #expect(decoded == snapshot)
    }

    @Test func publishIsChangeGated() throws {
        var snapshot = WidgetSnapshot(
            runningSessions: 1, pendingApprovals: 0, todayCostUSD: 0.5,
            updatedAt: .now, paired: true
        )
        // First publish always writes; an identical publish must be a no-op.
        let first = WidgetSnapshotStore.publishIfChanged(snapshot)
        let second = WidgetSnapshotStore.publishIfChanged(snapshot)
        #expect(first)
        #expect(!second)
        snapshot.pendingApprovals = 3
        #expect(WidgetSnapshotStore.publishIfChanged(snapshot))
        let stored = WidgetSnapshotStore.read()
        #expect(stored?.pendingApprovals == 3)
    }
}


private final class InMemoryQueuePersistence: QueuePersistence {
    var stored: [QueuedPrompt] = []
    func load() -> [QueuedPrompt] { stored }
    func save(_ items: [QueuedPrompt]) { stored = items }
}

struct OfflineQueueTests {
    @MainActor @Test func enqueuesInFifoOrder() {
        let queue = OfflinePromptQueue(persistence: InMemoryQueuePersistence())
        let a = QueuedPrompt(id: UUID(), text: "a", mode: "chat", role: "default", sessionId: "s1")
        let b = QueuedPrompt(id: UUID(), text: "b", mode: "chat", role: "default", sessionId: "s1")
        let c = QueuedPrompt(id: UUID(), text: "c", mode: "chat", role: "default", sessionId: "s1")
        queue.enqueue(a); queue.enqueue(b); queue.enqueue(c)
        #expect(queue.count == 3)
        #expect(queue.peek()?.id == a.id)             // FIFO: oldest first
        #expect(queue.removeFirst()?.id == a.id)
        #expect(queue.peek()?.id == b.id)
        #expect(queue.removeFirst()?.id == b.id)
        #expect(queue.removeFirst()?.id == c.id)
        #expect(queue.isEmpty)
    }

    @MainActor @Test func persistsAcrossReload() {
        let store = InMemoryQueuePersistence()
        let queue = OfflinePromptQueue(persistence: store)
        let a = QueuedPrompt(id: UUID(), text: "never dropped", mode: "chat", role: "default", sessionId: "s1")
        queue.enqueue(a)
        // A fresh queue over the same persistence must see the same item.
        let reloaded = OfflinePromptQueue(persistence: store)
        #expect(reloaded.count == 1)
        #expect(reloaded.peek()?.id == a.id)
        #expect(reloaded.peek()?.text == "never dropped")
    }

    @MainActor @Test func removalIsPersistedAndReorderable() {
        let store = InMemoryQueuePersistence()
        let queue = OfflinePromptQueue(persistence: store)
        let a = QueuedPrompt(id: UUID(), text: "a", mode: "chat", role: "default", sessionId: "s1")
        let b = QueuedPrompt(id: UUID(), text: "b", mode: "chat", role: "default", sessionId: "s1")
        queue.enqueue(a); queue.enqueue(b)
        #expect(queue.remove(id: a.id)?.id == a.id)
        #expect(queue.count == 1)
        #expect(queue.peek()?.id == b.id)
        let reloaded = OfflinePromptQueue(persistence: store)
        #expect(reloaded.count == 1)
        #expect(reloaded.peek()?.id == b.id)
    }

    @MainActor @Test func prunesStalePromptsOnLoad() {
        let store = InMemoryQueuePersistence()
        let stale = QueuedPrompt(
            id: UUID(), text: "old", mode: "chat", role: "default",
            createdAt: Date().addingTimeInterval(-8 * 86_400), sessionId: "s1"
        )
        let fresh = QueuedPrompt(id: UUID(), text: "new", mode: "chat", role: "default", sessionId: "s1")
        store.save([stale, fresh])
        let queue = OfflinePromptQueue(persistence: store)
        #expect(queue.count == 1)
        #expect(queue.peek()?.id == fresh.id)
    }
}

// MARK: - Reconnect state machine

struct ReconnectPolicyTests {
    @Test func networkFailureKeepsExponentialBackoff() {
        var policy = ReconnectPolicy()
        guard case .retry(let firstDelay, let quiet) = policy.decide(failure: .transportError) else {
            Issue.record("expected retry")
            return
        }
        #expect(firstDelay == 0.3)
        #expect(quiet == false)
        // Subsequent network failures back off harder, capped at the max.
        for _ in 0..<4 { _ = policy.decide(failure: .transportError) }
        guard case .retry(let grown, _) = policy.decide(failure: .transportError) else {
            Issue.record("expected retry")
            return
        }
        #expect(grown > firstDelay)
        var capped = ReconnectPolicy()
        for _ in 0..<30 { _ = capped.decide(failure: .transportError) }
        guard case .retry(let maxDelay, _) = capped.decide(failure: .transportError) else {
            Issue.record("expected retry")
            return
        }
        #expect(maxDelay <= 15.0)
    }

    @Test func unauthorizedStopsAsInvalidToken() {
        var policy = ReconnectPolicy()
        #expect(policy.decide(failure: .unauthorized) == .stop(.invalidToken))
    }

    @Test func revokedStopsAsInvalidToken() {
        var policy = ReconnectPolicy()
        #expect(policy.decide(failure: .revoked) == .stop(.invalidToken))
    }

    @Test func protocolMismatchStopsAsUpdateRequired() {
        var policy = ReconnectPolicy()
        #expect(policy.decide(failure: .protocolMismatch) == .stop(.updateRequired))
    }

    @Test func byeIsQuietImmediateRetry() {
        var policy = ReconnectPolicy()
        #expect(policy.decide(failure: .serverBye) == .retry(delay: 0.3, quiet: true))
    }

    @Test func serverByeAfterBackoffNeverShowsOfflineBanner() {
        var policy = ReconnectPolicy()
        for _ in 0..<4 { _ = policy.decide(failure: .transportError) }
        guard case .retry(_, let quiet) = policy.decide(failure: .serverBye) else {
            Issue.record("expected retry")
            return
        }
        #expect(quiet == true)
    }

    @Test func successResetsBackoff() {
        var policy = ReconnectPolicy()
        _ = policy.decide(failure: .transportError)
        _ = policy.decide(failure: .transportError)
        policy.resetAfterSuccess()
        #expect(policy.decide(failure: .transportError) == .retry(delay: 0.3, quiet: false))
    }
}

// MARK: - Multi-machine (contract I): routing table

struct MachineRouterTests {
    private let paired = [
        PairedMachineRecord(id: "m1", name: "devbox", host: "100.1.1.1:8674", pushKey: ""),
        PairedMachineRecord(id: "m2", name: "build-01", host: "100.1.1.2:8674", pushKey: "a2V5"),
    ]

    @Test func routesStoredSessionToItsOwningMachine() {
        let session = SessionSummary(
            id: "s1", title: "t", project: "p", cwd: "/src/p", sessionPath: "/x/s.jsonl",
            updatedAt: .now, live: false, status: .idle, shortId: "#1",
            machineId: "m2", machineName: "build-01"
        )
        #expect(MachineRouter.owningMachine(for: session, activeMachineId: "m1", paired: paired) == "m2")
    }

    @Test func routesUnknownSessionToActiveMachine() {
        // A summary with no machine tag (legacy/single-machine data) must
        // route to the active machine, not to nothing.
        let session = SessionSummary(
            id: "s1", title: "t", project: "p", cwd: "/src/p", sessionPath: "",
            updatedAt: .now, live: true, status: .idle, shortId: "#1"
        )
        #expect(MachineRouter.owningMachine(for: session, activeMachineId: "m1", paired: paired) == "m1")
    }

    @Test func fallsBackToFirstPairedMachineWhenActiveIsUnpaired() {
        let session = SessionSummary(
            id: "s1", title: "t", project: "p", cwd: "/src/p", sessionPath: "",
            updatedAt: .now, live: true, status: .idle, shortId: "#1"
        )
        #expect(MachineRouter.owningMachine(for: session, activeMachineId: "gone", paired: paired) == "m1")
    }

    @Test func sessionMachineOutsideRosterFallsBack() {
        let session = SessionSummary(
            id: "s1", title: "t", project: "p", cwd: "/src/p", sessionPath: "/x/s.jsonl",
            updatedAt: .now, live: false, status: .idle, shortId: "#1",
            machineId: "stale", machineName: "old"
        )
        #expect(MachineRouter.owningMachine(for: session, activeMachineId: "m2", paired: paired) == "m2")
    }

    @Test func nilSessionRoutesToActiveThenFirst() {
        #expect(MachineRouter.owningMachine(for: nil, activeMachineId: "m2", paired: paired) == "m2")
        #expect(MachineRouter.owningMachine(for: nil, activeMachineId: "gone", paired: paired) == "m1")
        #expect(MachineRouter.owningMachine(for: nil, activeMachineId: nil, paired: []) == nil)
    }
}

// MARK: - Multi-machine (contract I): settings migration

struct AppSettingsMigrationTests {
    /// A legacy single pairing must migrate into the per-machine store with
    /// host/name/token-presence intact, and the legacy keys must be dropped.
    @Test func migratesLegacySinglePairing() {
        let suite = "MigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("100.64.0.9:8674", forKey: "bridge.host")
        defaults.set("devbox", forKey: "bridge.machineName")
        defaults.set("abc123", forKey: "bridge.pushKey")

        let settings = AppSettings.load(defaults: defaults)

        #expect(settings.pairedMachines.count == 1)
        let record = settings.pairedMachines[0]
        #expect(record.host == "100.64.0.9:8674")
        #expect(record.name == "devbox")
        #expect(record.pushKey == "abc123")
        #expect(!record.id.isEmpty)
        // The migrated store is persisted and the legacy keys are gone.
        #expect(defaults.object(forKey: "bridge.host") == nil)
        let stored = try? JSONDecoder().decode(
            [PairedMachineRecord].self, from: defaults.data(forKey: "bridge.machines") ?? Data()
        )
        #expect(stored?.count == 1)
        #expect(stored?.first?.host == "100.64.0.9:8674")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func loadWithNoLegacyKeysYieldsEmptyStore() {
        let suite = "MigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings.load(defaults: defaults)
        #expect(settings.pairedMachines.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func loadKeepsExistingMultiMachineStore() {
        let suite = "MigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let existing = [
            PairedMachineRecord(id: "m1", name: "devbox", host: "100.1.1.1:8674", pushKey: ""),
            PairedMachineRecord(id: "m2", name: "build-01", host: "100.1.1.2:8674", pushKey: "a2V5"),
        ]
        defaults.set(try? JSONEncoder().encode(existing), forKey: "bridge.machines")
        // Simulate a legacy key lingering from a pre-migration build.
        defaults.set("stale.example:8674", forKey: "bridge.host")

        let settings = AppSettings.load(defaults: defaults)
        #expect(settings.pairedMachines.map(\.id) == ["m1", "m2"])   // untouched
        let stored = try? JSONDecoder().decode(
            [PairedMachineRecord].self, from: defaults.data(forKey: "bridge.machines") ?? Data()
        )
        #expect(stored?.map(\.id) == ["m1", "m2"])
        defaults.removePersistentDomain(forName: suite)
    }
}

// MARK: - Stream tool-run grouping

private func toolItem(_ verb: String = "bash", running: Bool = false) -> ChatItem {
    ChatItem(kind: .toolCard(ToolCardModel(
        icon: "✓", iconIsAccent: false, verb: verb, subject: "cmd", meta: "ok",
        detailLines: [], footer: nil, addCount: nil, delCount: nil, hashline: nil,
        running: running
    )))
}

struct StreamGroupingTests {
    @Test func collapsesThreeConsecutiveCompletedTools() {
        let items = [toolItem(), toolItem(), toolItem()]
        let units = StreamGrouping.renderUnits(from: items)
        #expect(units.count == 1)
        guard case .toolRun(let group) = units[0] else {
            Issue.record("expected a folded tool run, got \(units[0])")
            return
        }
        #expect(group.toolCount == 3)
        #expect(group.id == items[0].id) // stable id: first item in the run
    }

    @Test func keepsSubthresholdRunsAsIndividualItems() {
        let items = [toolItem(), toolItem()]
        let units = StreamGrouping.renderUnits(from: items)
        #expect(units.count == 2)
        for unit in units {
            if case .toolRun = unit { Issue.record("two tools must not collapse") }
        }
    }

    @Test func runningToolIsNeverFoldedAndBreaksAdjacentRuns() {
        let items = [
            toolItem("a"), toolItem("b"),                  // 2 → individual
            toolItem("running", running: true),            // in-flight, visible
            toolItem("c"), toolItem("d"), toolItem("e"),   // 3 → fold
        ]
        let units = StreamGrouping.renderUnits(from: items)
        #expect(units.count == 4)
        // Running tool stays as its own item at its exact position.
        #expect(units[2].id == items[2].id)
        guard case .toolRun(let tail) = units[3] else {
            Issue.record("expected a trailing folded run")
            return
        }
        #expect(tail.toolCount == 3)
    }

    @Test func nonToolItemsAreNeverFolded() {
        let items = [
            ChatItem(kind: .user("hi")), toolItem(), ChatItem(kind: .agentText("ok")),
        ]
        let units = StreamGrouping.renderUnits(from: items)
        #expect(units.count == 3)
        for (idx, unit) in units.enumerated() {
            if case .toolRun = unit { Issue.record("unit \(idx) must stay individual") }
        }
    }

    @Test func messageBetweenRunsYieldsTwoSeparateGroups() {
        let items = [
            toolItem("a"), toolItem("b"), toolItem("c"),
            ChatItem(kind: .user("split")),
            toolItem("d"), toolItem("e"), toolItem("f"),
        ]
        let units = StreamGrouping.renderUnits(from: items)
        #expect(units.count == 3)
        guard case .toolRun(let head) = units[0], case .item = units[1], case .toolRun(let tail) = units[2] else {
            Issue.record("expected [group, message, group]")
            return
        }
        #expect(head.toolCount == 3)
        #expect(tail.toolCount == 3)
        #expect(head.id != tail.id)
    }
}

// MARK: - Per-file diff sections

private func dtype(_ kind: DiffLine.Kind, _ text: String) -> DiffLine {
    DiffLine(kind: kind, text: text)
}

struct DiffSectionsTests {
    @Test func multiFileDiffSplitsIntoPerFileSections() {
        let lines = [
            dtype(.context, "diff --git a/src/a.go b/src/a.go"),
            dtype(.context, "index 1111..2222 100644"),
            dtype(.context, "--- a/src/a.go"),
            dtype(.context, "+++ b/src/a.go"),
            dtype(.hunk, "@@ -1,3 +1,4 @@ package a"),
            dtype(.add, "+new line"),
            dtype(.del, "-old line"),
            dtype(.context, " ctx"),
            dtype(.context, "diff --git a/src/b.go b/src/b.go"),
            dtype(.context, "--- a/src/b.go"),
            dtype(.context, "+++ b/src/b.go"),
            dtype(.hunk, "@@ -5,2 +5,3 @@ package b"),
            dtype(.add, "+more"),
        ]
        let sections = DiffSections.sections(from: lines)
        #expect(sections.count == 2)
        #expect(sections[0].path == "src/a.go")
        #expect(sections[0].addCount == 1)
        #expect(sections[0].delCount == 1)
        #expect(sections[1].path == "src/b.go")
        #expect(sections[1].addCount == 1)
        #expect(sections[1].delCount == 0)
    }

    @Test func pathPairsWithoutGitHeaderYieldOneSection() {
        let lines = [
            dtype(.context, "--- a/old.txt"),
            dtype(.context, "+++ b/new.txt"),
            dtype(.hunk, "@@ -1 +1 @@"),
            dtype(.add, "+x"),
            dtype(.del, "-y"),
        ]
        let sections = DiffSections.sections(from: lines)
        #expect(sections.count == 1)
        #expect(sections[0].path == "old.txt")
        #expect(sections[0].addCount == 1)
        #expect(sections[0].delCount == 1)
    }

    @Test func headerlessDiffStaysInSingleFallbackSection() {
        let lines = [
            dtype(.hunk, "@@ -1 +1 @@"),
            dtype(.add, "+x"),
            dtype(.del, "-y"),
            dtype(.context, " ctx"),
        ]
        let sections = DiffSections.sections(from: lines)
        #expect(sections.count == 1)
        #expect(sections[0].path == "(diff)")
        #expect(sections[0].addCount == 1)
        #expect(sections[0].delCount == 1)
    }

    @Test func headersAreNotCountedAsEdits() {
        let lines = [
            dtype(.context, "diff --git a/x.go b/x.go"),
            dtype(.context, "--- a/x.go"),
            dtype(.context, "+++ b/x.go"),
            dtype(.add, "+1"),
        ]
        let sections = DiffSections.sections(from: lines)
        #expect(sections.count == 1)
        #expect(sections[0].addCount == 1)
        #expect(sections[0].delCount == 0)
    }

    @Test func indexOnlyHeaderFallsBackToDiffLabel() {
        let lines = [
            dtype(.context, "Index: deadbeef"),
            dtype(.add, "+1"),
        ]
        let sections = DiffSections.sections(from: lines)
        #expect(sections.count == 1)
        #expect(sections[0].path == "(diff)")
        #expect(sections[0].addCount == 1)
    }

    @Test func aAndBPrefixesAreStrippedFromPaths() {
        let headers = ["diff --git a/x b/app/thing.swift", "diff --git app/other.go b/other.go"]
        for header in headers {
            let sections = DiffSections.sections(from: [dtype(.context, header), dtype(.add, "+1")])
            #expect(sections.count == 1)
            #expect(!sections[0].path.hasPrefix("a/"))
            #expect(!sections[0].path.hasPrefix("b/"))
        }
    }
}

// MARK: - Omp diff blob parsing (reused for diff-bearing approvals)

struct DiffBlobParsingTests {
    @MainActor @Test func plainOutputIsNotADiff() {
        #expect(BridgeEngine.parseDiffBlob("plain output\nno markers here") == nil)
        #expect(BridgeEngine.parseDiffBlob("") == nil)
    }

    @MainActor @Test func hunkWithoutEditsIsRejected() {
        #expect(BridgeEngine.parseDiffBlob("@@ -1,2 +1,2 @@\n list item\n plain context") == nil)
    }

    @MainActor @Test func parsesDiffCountsAndKeepsKinds() {
        let blob = "diff --git a/x b/x\n@@ -1 +1 @@ package x\n-old\n+new\n ctx"
        let parsed = BridgeEngine.parseDiffBlob(blob)
        #expect(parsed != nil)
        #expect(parsed?.adds == 1)
        #expect(parsed?.dels == 1)
        let kinds = parsed?.lines.map(\.kind) ?? []
        #expect(kinds.contains(.add))
        #expect(kinds.contains(.del))
        #expect(kinds.contains(.hunk))
    }

    @MainActor @Test func strippingHashlinePrefixes() {
        let blob = "@@ -1 +1 @@\na3f2| +new\nb1c3| -old"
        let parsed = BridgeEngine.parseDiffBlob(blob)
        #expect(parsed?.adds == 1)
        #expect(parsed?.dels == 1)
        for line in parsed?.lines ?? [] {
            if line.text.hasPrefix("a3f2") || line.text.hasPrefix("b1c3") {
                Issue.record("hashline prefix not stripped: \(line.text)")
            }
        }
    }

    @MainActor @Test func fileHeaderLinesAreNotEdits() {
        let blob = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n+a\n"
        let parsed = BridgeEngine.parseDiffBlob(blob)
        #expect(parsed?.adds == 1)
        #expect(parsed?.dels == 0)
    }

    @MainActor @Test func rejectsBogusAtAtInPlainText() {
        // "@@" alone (e.g. an email echo) with no +/- content must not parse.
        #expect(BridgeEngine.parseDiffBlob("meeting @@ attendees\nre: @+stripped?") == nil)
    }
}
