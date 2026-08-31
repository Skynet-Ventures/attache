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

struct BridgeError: Error, Equatable {
    let message: String
    var code: String?
}

// MARK: - Reconnect state machine

/// Why a connection attempt failed — feeds the reconnect policy so the app
/// can tell "network down" (retry with backoff) from "stop, user must act".
enum TransportFailure: Equatable {
    case transportError       // network-level: keep exponential backoff
    case unauthorized         // token rejected (HTTP 401 / invalid token)
    case protocolMismatch     // hello's protocolVersion unsupported
    case revoked              // token revoked by another surface
    case serverBye            // graceful bridge shutdown: quiet quick reconnect
}

enum ReconnectDecision: Equatable {
    case retry(delay: Double, quiet: Bool)
    case stop(AuthFailureKind)
}

/// Dependency-free reconnect policy. The auth-vs-network decision lives here
/// so the state machine transitions are unit-testable without any transport.
struct ReconnectPolicy {
    private(set) var attempt = 0
    private let baseDelay = 0.3
    private let maxDelay = 15.0
    private let factor = 1.6

    mutating func decide(failure: TransportFailure) -> ReconnectDecision {
        switch failure {
        case .transportError:
            let delay = attempt == 0 ? baseDelay : min(maxDelay, pow(factor, Double(attempt)))
            attempt += 1
            return .retry(delay: delay, quiet: false)
        case .serverBye:
            attempt = 0
            return .retry(delay: baseDelay, quiet: true)
        case .unauthorized, .revoked:
            return .stop(.invalidToken)
        case .protocolMismatch:
            return .stop(.updateRequired)
        }
    }

    mutating func resetAfterSuccess() {
        attempt = 0
    }
}

/// Terminal failure kinds surfaced to the UI.
enum AuthFailureKind: Equatable {
    case invalidToken
    case updateRequired
}

/// Forwards the URLSession delegate (nonisolated, background thread) onto the
/// main actor so BridgeClient can see the WebSocket handshake HTTP status.
private final class WSDelegateForwarder: NSObject, URLSessionWebSocketDelegate, URLSessionDataDelegate {
    /// Reports the HTTP status of a WS handshake response (nil if unknown).
    var onHandshakeResponse: ((Int?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
        onHandshakeResponse?((response as? HTTPURLResponse)?.statusCode)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        onClose?(closeCode)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {}
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
    private let forwarder: WSDelegateForwarder?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var requestCounter = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var heartbeatTask: Task<Void, Never>?
    private var offlineGraceTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectPolicy = ReconnectPolicy()
    /// HTTP status captured from the latest WS handshake (nil if unknown).
    private var handshakeStatus: Int?
    private(set) var authFailure: AuthFailureKind?

    var onEvent: ((String, JSONValue) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onAuthFailure: ((AuthFailureKind) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    init(host: String, token: String, urlSession: URLSession? = nil) {
        self.host = host
        self.token = token
        if let urlSession {
            // Injected transport (tests) — no handshake-status capture.
            self.forwarder = nil
            self.session = urlSession
        } else {
            self.forwarder = WSDelegateForwarder()
            self.session = URLSession(
                configuration: .ephemeral,
                delegate: forwarder,
                delegateQueue: nil
            )
        }
    }

    // MARK: Pairing (static, pre-token)

    static func pair(host: String, code: String, deviceName: String) async throws -> (
        token: String, machineName: String, pushKey: String
    ) {
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
        // Contract H: newer bridges hand over a per-device AES key for APNs
        // payload encryption. Absent on legacy bridges — tolerated as "".
        let pushKey = json["pushKey"]?.stringValue ?? ""
        return (token, name, pushKey)
    }

    // MARK: Connection lifecycle

    func connect() {
        closed = false
        authFailure = nil
        reconnectPolicy.resetAfterSuccess()
        handshakeStatus = nil
        openSocket()
    }

    func close() {
        closed = true
        reconnectTask?.cancel()
        heartbeatTask?.cancel()
        offlineGraceTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    private func openSocket() {
        guard !closed, authFailure == nil, let url = URL(string: "ws://\(host)/ws?token=\(token)") else { return }
        // Stay in .connecting during silent retries; .offline (the red
        // banner) only arrives via the grace timer below.
        if state != .offline { state = .connecting }
        handshakeStatus = nil
        forwarder?.onHandshakeResponse = { [weak self] status in
            guard let self else { return }
            Task { @MainActor in self.noteHandshakeStatus(status) }
        }
        forwarder?.onClose = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.noteClosedByServer() }
        }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)
        // A successful first receive flips to .connected; probe with a ping.
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                if error == nil {
                    self.markConnected()
                } else if let status = self.handshakeStatus, status == 401 || status == 403 {
                    self.enterAuthFailure(.invalidToken)
                } else {
                    self.scheduleReconnect(failure: .transportError)
                }
            }
        }
    }

    /// The handshake response status — HTTP 401/403 means the token was
    /// rejected at upgrade time; stop retrying instead of looping.
    private func noteHandshakeStatus(_ status: Int?) {
        handshakeStatus = status
        if status == 401 || status == 403, authFailure == nil {
            enterAuthFailure(.invalidToken)
        }
    }

    /// The server closed the socket (e.g. revoked-token teardown after the
    /// `revoked` error frame). If the auth failure path already stopped the
    /// reconnect loop this is a no-op.
    private func noteClosedByServer() {
        if authFailure == nil, state == .connected {
            scheduleReconnect(failure: .transportError)
        }
    }

    /// Terminal: stop retrying and tell the app why.
    private func enterAuthFailure(_ kind: AuthFailureKind) {
        guard authFailure == nil else { return }
        authFailure = kind
        reconnectTask?.cancel()
        heartbeatTask?.cancel()
        offlineGraceTask?.cancel()
        offlineGraceTask = nil
        failAllPending(BridgeError(
            message: kind == .updateRequired ? "protocol mismatch — update required" : "device token rejected",
            code: kind == .updateRequired ? "protocol_mismatch" : "revoked"
        ))
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
        onAuthFailure?(kind)
    }

    private func markConnected() {
        offlineGraceTask?.cancel()
        offlineGraceTask = nil
        reconnectPolicy.resetAfterSuccess()
        handshakeStatus = nil
        state = .connected
        startHeartbeat()
    }

    /// Keepalive: ping every 25s so neither the bridge's idle culling nor a
    /// silently dead TCP path can leave a zombie connection. A failed ping
    /// tears the socket down, which routes into the reconnect path.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let task = task
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, self.task === task, let task else { return }
                task.sendPing { error in
                    if error != nil {
                        task.cancel(with: .abnormalClosure, reason: nil)
                    }
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
                    // Deliberate teardowns (bye/auth failure) already own the
                    // reconnect path — and nil out `task`, so the guard above
                    // stops us from double-scheduling.
                    if self.authFailure == nil {
                        self.scheduleReconnect(failure: .transportError)
                    }
                }
            }
        }
    }

    private func scheduleReconnect(failure: TransportFailure) {
        guard !closed, authFailure == nil else { return }
        switch reconnectPolicy.decide(failure: failure) {
        case .stop(let kind):
            enterAuthFailure(kind)
        case .retry(let delay, let quiet):
            heartbeatTask?.cancel()
            if quiet {
                // Graceful shutdown (bye): reconnect promptly and silently —
                // never flip the red offline banner.
                offlineGraceTask?.cancel()
                offlineGraceTask = nil
                state = .connecting
            } else if state == .connected {
                state = .connecting
            }
            if !quiet, offlineGraceTask == nil {
                // Silent fast retries first — the red offline state only shows
                // if we stay disconnected past the grace window (stops banner
                // flapping on sub-second reconnects).
                offlineGraceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard let self, !Task.isCancelled else { return }
                    self.offlineGraceTask = nil
                    if self.state != .connected { self.state = .offline }
                }
            }
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !self.closed, self.authFailure == nil else { return }
                self.openSocket()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = frame["type"]?.stringValue else { return }
        if state != .connected { markConnected() }
        if type == "bye" {
            handleBye(frame)
            return
        }
        if type == "result", let id = frame["id"]?.stringValue, let cont = pending.removeValue(forKey: id) {
            if frame["ok"]?.boolValue == true {
                cont.resume(returning: frame["data"] ?? .null)
            } else {
                let code = frame["code"]?.stringValue
                let message = frame["error"]?.stringValue ?? "command failed"
                // Terminal protocol/credential errors stop the reconnect loop;
                // the app surfaces re-pair / update-required states.
                switch code {
                case "protocol_mismatch":
                    cont.resume(throwing: BridgeError(message: message, code: code))
                    enterAuthFailure(.updateRequired)
                case "revoked":
                    cont.resume(throwing: BridgeError(message: message, code: code))
                    enterAuthFailure(.invalidToken)
                default:
                    cont.resume(throwing: BridgeError(message: message, code: code))
                }
            }
            return
        }
        onEvent?(type, frame)
    }

    /// Graceful bridge shutdown: fail in-flight commands, then reconnect
    /// promptly and quietly. No offline banner, no backoff storm.
    private func handleBye(_ frame: JSONValue) {
        let reason = frame["reason"]?.stringValue ?? "bridge is shutting down"
        failAllPending(BridgeError(message: reason, code: "bye"))
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        scheduleReconnect(failure: .serverBye)
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
