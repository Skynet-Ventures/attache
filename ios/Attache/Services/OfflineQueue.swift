import Foundation

/// Storage behind the offline prompt queue. Abstracted so unit tests can
/// inject an in-memory store; the app uses UserDefaults-backed persistence.
protocol QueuePersistence: AnyObject {
    func load() -> [QueuedPrompt]
    func save(_ items: [QueuedPrompt])
}

final class UserDefaultsQueuePersistence: QueuePersistence {
    private let defaults: UserDefaults
    private let key = "offline.queue"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [QueuedPrompt] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([QueuedPrompt].self, from: data) else { return [] }
        return items
    }

    func save(_ items: [QueuedPrompt]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

/// FIFO queue of prompts composed while the bridge was unreachable. Prompts
/// survive app restarts (persisted) and are flushed in order once the session
/// they were composed in is re-attached.
@MainActor
final class OfflinePromptQueue {
    private(set) var items: [QueuedPrompt] = []
    private let persistence: QueuePersistence
    /// Prompts older than this are dropped on load — they can't be meaningfully
    /// delivered after the session is long gone.
    private let maxAge: TimeInterval = 7 * 86_400

    init(persistence: QueuePersistence) {
        self.persistence = persistence
        let cutoff = Date().addingTimeInterval(-maxAge)
        items = persistence.load().filter { $0.createdAt > cutoff }
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// Next item in FIFO order, or nil when the queue is empty.
    func peek() -> QueuedPrompt? { items.first }

    func enqueue(_ prompt: QueuedPrompt) {
        items.append(prompt)
        persist()
    }

    func removeFirst() -> QueuedPrompt? {
        guard !items.isEmpty else { return nil }
        let removed = items.removeFirst()
        persist()
        return removed
    }

    @discardableResult
    func remove(id: UUID) -> QueuedPrompt? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: idx)
        persist()
        return removed
    }

    private func persist() {
        persistence.save(items)
    }
}
