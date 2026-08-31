import Foundation

/// Minimal dynamic JSON value — the bridge forwards omp event frames whose
/// shapes evolve; we stay tolerant instead of strictly Codable.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown json") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    var intValue: Int? { doubleValue.map(Int.init) }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

struct BridgeError: Error {
    let message: String
}

/// WebSocket + REST client for attache-bridge. All callbacks hop to the main
/// actor; commands are correlated by id.
@MainActor
final class BridgeClient {
    enum State: Equatable {
        case idle, connecting, connected, offline
    }

    private let host: String
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var requestCounter = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var reconnectAttempt = 0
    private var closed = false

    var onEvent: ((String, JSONValue) -> Void)?
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    init(host: String, token: String) {
        self.host = host
        self.token = token
    }

    // MARK: Pairing (static, pre-token)

    static func pair(host: String, code: String, deviceName: String) async throws -> (token: String, machineName: String) {
        guard let url = URL(string: "http://\(host)/pair") else {
            throw BridgeError(message: "invalid address")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "deviceName": deviceName])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BridgeError(message: "no response") }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard http.statusCode == 200, let token = json["token"]?.stringValue else {
            throw BridgeError(message: json["error"]?.stringValue ?? "pairing failed (\(http.statusCode))")
        }
        let name = json["machine"]?["name"]?.stringValue ?? "machine"
        return (token, name)
    }

    // MARK: Connection lifecycle

    func connect() {
        closed = false
        openSocket()
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    private func openSocket() {
        guard !closed, let url = URL(string: "ws://\(host)/ws?token=\(token)") else { return }
        state = reconnectAttempt == 0 ? .connecting : .offline
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)
        // A successful first receive flips to .connected; probe with a ping.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                if error == nil {
                    self.state = .connected
                    self.reconnectAttempt = 0
                } else {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    else if case .data(let data) = message, let text = String(data: data, encoding: .utf8) {
                        self.handle(text)
                    }
                    self.receiveLoop(task)
                case .failure:
                    self.failAllPending(BridgeError(message: "connection lost"))
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        state = .offline
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = min(15.0, pow(1.6, Double(attempt)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.closed else { return }
            self.openSocket()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = frame["type"]?.stringValue else { return }
        state = .connected
        if type == "result", let id = frame["id"]?.stringValue, let cont = pending.removeValue(forKey: id) {
            if frame["ok"]?.boolValue == true {
                cont.resume(returning: frame["data"] ?? .null)
            } else {
                cont.resume(throwing: BridgeError(message: frame["error"]?.stringValue ?? "command failed"))
            }
            return
        }
        onEvent?(type, frame)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }

    // MARK: Commands

    @discardableResult
    func send(_ type: String, _ payload: [String: Any] = [:]) async throws -> JSONValue {
        guard let task else { throw BridgeError(message: "not connected") }
        requestCounter += 1
        let id = "app_\(requestCounter)"
        var object: [String: Any] = payload
        object["id"] = id
        object["type"] = type
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8)!
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            task.send(.string(text)) { [weak self] error in
                if let error {
                    Task { @MainActor in
                        if let cont = self?.pending.removeValue(forKey: id) {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    /// REST verdict fallback used by notification actions (no WS required).
    static func postVerdict(host: String, token: String, sessionId: String?, approvalId: String, verdict: Verdict) async {
        guard let url = URL(string: "http://\(host)/verdict") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        var body: [String: Any] = ["token": token, "approvalId": approvalId, "verdict": verdict.rawValue]
        if let sessionId { body["sessionId"] = sessionId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
