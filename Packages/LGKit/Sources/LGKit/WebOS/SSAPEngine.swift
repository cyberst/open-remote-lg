import Foundation

/// Timing knobs. Production defaults; tests shrink them.
struct SSAPTiming: Sendable {
    var connectTimeout: TimeInterval = 5
    var requestTimeout: TimeInterval = 8
    /// How long the TV may wait for the user to accept the prompt / type the PIN.
    var pairingTimeout: TimeInterval = 60
    var pingInterval: TimeInterval = 20
    var pingTimeout: TimeInterval = 5
    /// Delay before each reconnect attempt; the last value repeats.
    var backoff: [TimeInterval] = [0.5, 1, 2, 4, 8, 10]
    var maxReconnectAttempts = 12
    /// When the socket type is unknown, wss:3001 gets this head start before ws:3000 is tried in parallel.
    var secureHeadStart: TimeInterval = 0.35
    /// With a remembered port, how long it gets before the other port is tried in parallel. A booting TV accepts
    /// TCP on its old port but can stall the WebSocket handshake for the whole connect timeout.
    var preferredHeadStart: TimeInterval = 1.5

    func backoffDelay(attempt: Int) -> TimeInterval {
        guard !backoff.isEmpty else { return 0 }
        return backoff[min(max(attempt - 1, 0), backoff.count - 1)]
    }
}

/// The SSAP (webOS "Second Screen Application Protocol") session: one WebSocket to the TV carrying JSON
/// request/response/subscription messages. Owns connecting, pairing, keepalive and automatic reconnection.
actor SSAPEngine {
    let host: String
    private let deviceID: String
    private let keyStore: ClientKeyStoring
    private let factory: WebSocketTransportFactory
    private let timing: SSAPTiming
    let stateOut: Broadcaster<ConnectionState>
    private let log: (@Sendable (String) -> Void)?

    /// nil = unknown (race 3001/3000). Updated to whatever worked.
    private(set) var securePreference: Bool?
    /// Called (on the engine) every time a session is (re-)established, e.g. to drop a stale pointer socket.
    private let onConnected: (@Sendable () async -> Void)?

    private var state: ConnectionState = .disconnected
    private var socket: WebSocketTransport?
    private var generation = 0
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    /// False after `disconnect()`: no auto-reconnect, requests fail fast.
    private var wantsConnection = false
    /// Some firmware ignores WebSocket ping frames; we then probe liveness with a cheap SSAP request.
    private var pingFramesUnsupported = false

    private struct Pending {
        let continuation: CheckedContinuation<JSON, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    private struct Subscription {
        let uri: String
        let payload: JSON?
        let handler: @Sendable (JSON) -> Void
        var messageID: String?
    }
    private var subscriptions: [String: Subscription] = [:]   // by key
    private var subscriptionKeyByID: [String: String] = [:]   // message id → key

    private struct Registration {
        var id: String
        var sentKey: Bool
        var retriedWithoutKey = false
        let preferPIN: Bool
        var continuation: CheckedContinuation<Void, Error>?
        var timeout: Task<Void, Never>?
    }
    private var registration: Registration?

    private var waiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
    private var counter = 0

    init(host: String, deviceID: String, secure: Bool?, keyStore: ClientKeyStoring,
         factory: WebSocketTransportFactory, timing: SSAPTiming, stateOut: Broadcaster<ConnectionState>,
         log: (@Sendable (String) -> Void)? = nil, onConnected: (@Sendable () async -> Void)? = nil) {
        self.host = host; self.deviceID = deviceID; self.securePreference = secure; self.keyStore = keyStore
        self.factory = factory; self.timing = timing; self.stateOut = stateOut; self.log = log; self.onConnected = onConnected
    }

    var currentState: ConnectionState { state }
    var isUp: Bool { state == .connected && socket != nil }
    /// Whether the live socket is wss (nil when not connected).
    private(set) var socketIsSecure: Bool?

    // MARK: - Public lifecycle

    func connect(preferPIN: Bool) async throws {
        wantsConnection = true
        // Already up: verify with a quick ping. After iOS suspends the app the socket often looks open but is
        // dead; this turns "connect() on foreground" into a fast, reliable resume.
        if isUp, await quickLivenessCheck() { return }
        if let r = reconnectTask { r.cancel(); reconnectTask = nil }
        do {
            try await runEstablish(preferPIN: preferPIN, isReconnect: false)
        } catch {
            guard wantsConnection else { throw LGError.notConnected }
            if !isUp {
                setState(.failed(Self.describe(error)))
                resumeWaiters(error)
            }
            throw error
        }
    }

    /// True if the live socket answers within ~1.5 s (or the firmware is known not to answer pings).
    private func quickLivenessCheck() async -> Bool {
        guard let sock = socket else { return false }
        if pingFramesUnsupported { return true }
        let gen = generation
        do {
            try await sock.ping(timeout: min(timing.pingTimeout, 1.5))
            return true
        } catch {
            log?("socket dead on connect() (\(error)); reconnecting now")
            await socketDidFail(generation: gen, error: error)
            return isUp
        }
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        socket?.close()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel(); reconnectTask = nil
        connectTask?.cancel()
        teardownSocket(LGError.notConnected)
        setState(.disconnected)
        resumeWaiters(LGError.notConnected)
    }

    /// Sends the PIN shown on the TV while in `.pairing(.enterPIN)`.
    func submitPIN(_ pin: String) async throws {
        guard registration != nil, socket != nil else { throw LGError.notConnected }
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await sendRequest(type: "request", uri: "ssap://pairing/setPin", payload: ["pin": .string(trimmed)],
                                  timeout: timing.requestTimeout)
    }

    // MARK: - Requests & subscriptions

    func request(_ uri: String, payload: JSON?, timeout: TimeInterval? = nil) async throws -> JSON {
        let t = timeout ?? timing.requestTimeout
        try await waitUntilConnected(timeout: t)
        do {
            return try await sendRequest(type: "request", uri: uri, payload: payload, timeout: t)
        } catch LGError.timeout {
            // A silent timeout often means the Wi-Fi path died; check the socket now instead of in 20 s.
            Task { await self.checkLiveness(generation: self.generation) }
            throw LGError.timeout
        }
    }

    /// Registers a subscription that survives reconnects. Idempotent per `key`.
    func subscribe(key: String, uri: String, payload: JSON?, handler: @escaping @Sendable (JSON) -> Void) {
        guard subscriptions[key] == nil else { return }
        subscriptions[key] = Subscription(uri: uri, payload: payload, handler: handler)
        if isUp { sendSubscribe(key: key) }
    }

    /// Requests a pointer-input socket URL from the TV.
    func pointerSocketURL() async throws -> URL {
        let p = try await request("ssap://com.webos.service.networkinput/getPointerInputSocket", payload: nil)
        guard let path = p["socketPath"]?.stringValue, let url = URL(string: path) else {
            throw LGError.tvError("The TV did not return a pointer socket.")
        }
        return url
    }

    // MARK: - Establishing

    private func runEstablish(preferPIN: Bool, isReconnect: Bool) async throws {
        if let t = connectTask { return try await t.value }
        let t = Task { try await self.establish(preferPIN: preferPIN, isReconnect: isReconnect) }
        connectTask = t
        defer { connectTask = nil }
        try await t.value
    }

    private func establish(preferPIN: Bool, isReconnect: Bool) async throws {
        if !isReconnect { setState(.connecting) }
        let (sock, secure) = try await openSocket()
        if Task.isCancelled || !wantsConnection { sock.close(); throw LGError.notConnected }
        teardownSocket(LGError.network("Replaced by a new connection"))
        generation += 1
        let gen = generation
        socket = sock
        socketIsSecure = secure
        startReceiving(sock, generation: gen)
        do {
            try await register(preferPIN: preferPIN)
        } catch {
            if generation == gen { teardownSocket(error) }
            throw error
        }
        // Invalidate per-session resources (pointer socket) before anyone can observe `.connected`.
        if let onConnected { await onConnected() }
        guard generation == gen, socket != nil else { throw LGError.network("Connection lost") }
        securePreference = secure
        pingFramesUnsupported = false
        setState(.connected)
        startPinging(generation: gen)
        for key in subscriptions.keys { sendSubscribe(key: key) }
        resumeWaiters(nil)
    }

    private func url(secure: Bool) -> URL? {
        URL(string: secure ? "wss://\(SSAPParsers.hostForURL(host)):3001/" : "ws://\(SSAPParsers.hostForURL(host)):3000/")
    }

    /// Opens a socket. Known preference → that port first, the other in parallel after `preferredHeadStart`. Unknown → wss:3001 with a head
    /// start, ws:3000 in parallel; first to open wins (2022+ firmware only serves 3001, some old firmware only 3000).
    private func openSocket() async throws -> (WebSocketTransport, Bool) {
        if let pref = securePreference {
            return try await openFirst([pref, !pref], stagger: timing.preferredHeadStart)
        }
        return try await openFirst([true, false], stagger: timing.secureHeadStart)
    }

    private func openFirst(_ options: [Bool], stagger: TimeInterval) async throws -> (WebSocketTransport, Bool) {
        let candidates: [(WebSocketTransport, Bool)] = options.compactMap { secure in
            url(secure: secure).map { (factory.makeTransport(url: $0), secure) }
        }
        guard !candidates.isEmpty else { throw LGError.network("Invalid TV address \(host)") }
        let connectTimeout = timing.connectTimeout
        let log = self.log
        let winner: Int? = await withTaskGroup(of: (Int, Error?).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask {
                    if i > 0, stagger > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(stagger * Double(i) * 1_000_000_000))
                    }
                    if Task.isCancelled { return (i, CancellationError()) }
                    do { try await c.0.open(timeout: connectTimeout); return (i, nil) } catch { return (i, error) }
                }
            }
            var winner: Int?
            for await (i, error) in group {
                if let error {
                    if !(error is CancellationError) { log?("open \(candidates[i].1 ? "wss:3001" : "ws:3000") failed: \(error)") }
                    continue
                }
                if winner == nil { winner = i; group.cancelAll() } else { candidates[i].0.close() }
            }
            return winner
        }
        guard let winner else {
            candidates.forEach { $0.0.close() }
            throw LGError.network("Could not reach the TV at \(host). Make sure it is on and on the same network.")
        }
        for (i, c) in candidates.enumerated() where i != winner { c.0.close() }
        log?("socket open on \(candidates[winner].1 ? "wss:3001" : "ws:3000")")
        return candidates[winner]
    }

    // MARK: - Registration / pairing

    private func register(preferPIN: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Task { await self.beginRegistration(preferPIN: preferPIN, continuation: c) }
        }
    }

    private func beginRegistration(preferPIN: Bool, continuation: CheckedContinuation<Void, Error>) async {
        if let old = registration?.continuation { old.resume(throwing: LGError.network("Superseded")) }
        let key = keyStore.clientKey(for: deviceID)
        let id = nextID("register")
        registration = Registration(id: id, sentKey: key != nil, preferPIN: preferPIN, continuation: continuation)
        armRegistrationTimeout(timing.requestTimeout)
        await sendRegister(id: id, key: key, preferPIN: preferPIN)
    }

    private func sendRegister(id: String, key: String?, preferPIN: Bool) async {
        let msg: JSON = ["type": "register", "id": .string(id), "payload": RegistrationManifest.payload(clientKey: key, pin: preferPIN)]
        do { try await sendJSON(msg) } catch { finishRegistration(error) }
    }

    private func armRegistrationTimeout(_ seconds: TimeInterval) {
        registration?.timeout?.cancel()
        guard let id = registration?.id else { return }
        registration?.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.registrationTimedOut(id: id)
        }
    }

    private func registrationTimedOut(id: String) {
        guard let r = registration, r.id == id else { return }
        if case .pairing = state { log?("pairing timed out") }
        finishRegistration(LGError.timeout)
    }

    private func finishRegistration(_ error: Error?) {
        guard var r = registration else { return }
        r.timeout?.cancel()
        let c = r.continuation
        r.continuation = nil
        registration = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    private func handleRegistrationMessage(_ msg: JSON) async {
        guard var r = registration else { return }
        let type = msg["type"]?.stringValue ?? ""
        switch type {
        case "response":
            guard let pairingType = msg["payload"]?["pairingType"]?.stringValue else { return }
            if r.sentKey {
                // The TV ignored our key and is asking for pairing: the stored key is no longer valid.
                log?("stored client key not accepted; pairing again")
                keyStore.setClientKey(nil, for: deviceID)
                r.sentKey = false
                registration = r
            }
            setState(.pairing(pairingType.uppercased() == "PIN" ? .enterPIN : .acceptOnTV))
            armRegistrationTimeout(timing.pairingTimeout)
        case "registered":
            if let key = msg["payload"]?["client-key"]?.stringValue, !key.isEmpty {
                keyStore.setClientKey(key, for: deviceID)
            }
            finishRegistration(nil)
        case "error":
            let text = SSAPParsers.errorText(msg)
            if Self.isDenial(text) {
                if r.sentKey { keyStore.setClientKey(nil, for: deviceID) }
                finishRegistration(LGError.pairingRejected)
            } else if r.sentKey && !r.retriedWithoutKey {
                // Rejected key (some firmware answers with an error instead of prompting): forget it and pair again.
                log?("register error with stored key (\(text)); retrying without key")
                keyStore.setClientKey(nil, for: deviceID)
                r.sentKey = false
                r.retriedWithoutKey = true
                r.id = nextID("register")
                registration = r
                armRegistrationTimeout(timing.requestTimeout)
                await sendRegister(id: r.id, key: nil, preferPIN: r.preferPIN)
            } else {
                finishRegistration(LGError.tvError(text))
            }
        default:
            break
        }
    }

    static func isDenial(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("denied") || t.contains("reject") || t.contains("cancel") || t.hasPrefix("403")
    }

    // MARK: - Socket I/O

    private func startReceiving(_ sock: WebSocketTransport, generation gen: Int) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await sock.receive()
                    await self?.handle(text: text, generation: gen)
                } catch {
                    await self?.socketDidFail(generation: gen, error: error)
                    return
                }
            }
        }
    }

    private func handle(text: String, generation gen: Int) async {
        guard gen == generation else { return }
        log?("<- \(text.count > 600 ? String(text.prefix(600)) + "…" : text)")
        guard let data = text.data(using: .utf8), let msg = try? JSON.parse(data) else { return }
        guard let id = msg["id"]?.stringValue else { return }
        if registration?.id == id { await handleRegistrationMessage(msg); return }
        if let p = pending.removeValue(forKey: id) {
            p.timeout.cancel()
            switch Self.result(of: msg) {
            case .success(let payload): p.continuation.resume(returning: payload)
            case .failure(let error): p.continuation.resume(throwing: error)
            }
            return
        }
        if let key = subscriptionKeyByID[id], let sub = subscriptions[key] {
            if case .success(let payload) = Self.result(of: msg) { sub.handler(payload) }
            else { log?("subscription \(sub.uri) error: \(SSAPParsers.errorText(msg))") }
        }
    }

    /// Maps an SSAP reply to a payload or an `LGError`.
    static func result(of msg: JSON) -> Result<JSON, LGError> {
        let payload = msg["payload"] ?? .object([:])
        if msg["type"]?.stringValue == "error" || payload["returnValue"]?.boolValue == false {
            let text = SSAPParsers.errorText(msg)
            if text.hasPrefix("404") { return .failure(.unsupported(text)) }
            return .failure(.tvError(text))
        }
        return .success(payload)
    }

    private func sendJSON(_ msg: JSON) async throws {
        guard let sock = socket else { throw LGError.notConnected }
        let data = try msg.data()
        let text = String(decoding: data, as: UTF8.self)
        log?("-> \(text.count > 600 ? String(text.prefix(600)) + "…" : text)")
        do { try await sock.send(text) } catch {
            await socketDidFail(generation: generation, error: error)
            throw LGError.network(Self.describe(error))
        }
    }

    private func sendRequest(type: String, uri: String, payload: JSON?, timeout: TimeInterval) async throws -> JSON {
        let id = nextID(type == "subscribe" ? "sub" : "req")
        var msg: [String: JSON] = ["type": .string(type), "id": .string(id), "uri": .string(uri)]
        if let payload { msg["payload"] = payload }
        let message = JSON.object(msg)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            Task { await self.dispatch(id: id, message: message, timeout: timeout, continuation: c) }
        }
    }

    private func dispatch(id: String, message: JSON, timeout: TimeInterval, continuation: CheckedContinuation<JSON, Error>) async {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.expire(id: id)
        }
        pending[id] = Pending(continuation: continuation, timeout: timeoutTask)
        do { try await sendJSON(message) } catch {
            if let p = pending.removeValue(forKey: id) { p.timeout.cancel(); p.continuation.resume(throwing: error) }
        }
    }

    private func expire(id: String) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: LGError.timeout)
    }

    private func sendSubscribe(key: String) {
        guard var sub = subscriptions[key] else { return }
        if let old = sub.messageID { subscriptionKeyByID.removeValue(forKey: old) }
        let id = nextID("sub")
        sub.messageID = id
        subscriptions[key] = sub
        subscriptionKeyByID[id] = key
        var msg: [String: JSON] = ["type": "subscribe", "id": .string(id), "uri": .string(sub.uri)]
        if let p = sub.payload { msg["payload"] = p }
        Task { try? await self.sendJSON(.object(msg)) }
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }

    // MARK: - Keepalive

    private func startPinging(generation gen: Int) {
        pingTask?.cancel()
        let interval = timing.pingInterval
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.checkLiveness(generation: gen)
            }
        }
    }

    /// Ping frame first; if the firmware never answers pings, fall back to a cheap SSAP round trip.
    func checkLiveness(generation gen: Int) async {
        guard gen == generation, let sock = socket, registration == nil else { return }
        if !pingFramesUnsupported {
            do { try await sock.ping(timeout: timing.pingTimeout); return } catch {
                guard gen == generation else { return }
                log?("ping failed (\(error)); probing with an SSAP request")
            }
        }
        do {
            _ = try await sendRequest(type: "request", uri: "ssap://audio/getVolume", payload: nil, timeout: timing.pingTimeout)
            pingFramesUnsupported = true
        } catch LGError.timeout {
            await socketDidFail(generation: gen, error: LGError.timeout)
        } catch {
            // Any SSAP-level answer (even an error) proves the socket is alive.
            if case LGError.tvError = error { pingFramesUnsupported = true; return }
            if case LGError.unsupported = error { pingFramesUnsupported = true; return }
            await socketDidFail(generation: gen, error: error)
        }
    }

    // MARK: - Failure & reconnection

    func socketDidFailForTesting() async {
        await socketDidFail(generation: generation, error: LGError.network("Simulated drop"))
    }

    private func socketDidFail(generation gen: Int, error: Error) async {
        guard gen == generation, socket != nil else { return }
        log?("socket failed: \(error)")
        let wasConnected = state == .connected
        teardownSocket(LGError.network("Connection to the TV was lost."))
        if wasConnected && wantsConnection { startReconnecting() }
    }

    private func startReconnecting() {
        guard reconnectTask == nil else { return }
        // Set synchronously so callers that wait right after kicking a reconnect don't see the old `.failed`.
        setState(.reconnecting(attempt: 1))
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        defer { if !Task.isCancelled { reconnectTask = nil } }
        var lastError: Error = LGError.network("Connection lost")
        for attempt in 1...max(1, timing.maxReconnectAttempts) {
            guard wantsConnection, !Task.isCancelled else { return }
            setState(.reconnecting(attempt: attempt))
            try? await Task.sleep(nanoseconds: UInt64(timing.backoffDelay(attempt: attempt) * 1_000_000_000))
            guard wantsConnection, !Task.isCancelled else { return }
            if isUp { return }
            do {
                try await runEstablish(preferPIN: false, isReconnect: true)
                return
            } catch {
                lastError = error
                if Task.isCancelled || !wantsConnection { return }
                if isUp { return }
                if case LGError.pairingRejected = error { break }
                log?("reconnect attempt \(attempt) failed: \(error)")
            }
        }
        guard wantsConnection, !Task.isCancelled, !isUp else { return }
        setState(.failed(Self.describe(lastError)))
        resumeWaiters(lastError)
    }

    private func teardownSocket(_ error: Error) {
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        socket?.close(); socket = nil
        socketIsSecure = nil
        generation += 1
        for (_, p) in pending { p.timeout.cancel(); p.continuation.resume(throwing: error) }
        pending.removeAll()
        subscriptionKeyByID.removeAll()
        for key in subscriptions.keys { subscriptions[key]?.messageID = nil }
        if registration != nil { finishRegistration(error) }
    }

    // MARK: - Waiting for a connection

    /// Returns when connected. While reconnecting (or after a failed reconnect) it waits for/kicks a new attempt
    /// so a button press right after Wi-Fi comes back still goes through.
    private func waitUntilConnected(timeout: TimeInterval) async throws {
        if isUp { return }
        guard wantsConnection else { throw LGError.notConnected }
        switch state {
        case .pairing, .disconnected: throw LGError.notConnected
        case .failed: startReconnecting()
        default: break
        }
        let id = UUID()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Task { self.addWaiter(id: id, timeout: timeout, continuation: c) }
        }
    }

    private func addWaiter(id: UUID, timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        if isUp { continuation.resume(); return }
        if case .failed(let m) = state { continuation.resume(throwing: LGError.network(m)); return }
        if !wantsConnection { continuation.resume(throwing: LGError.notConnected); return }
        let t = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.expireWaiter(id: id)
        }
        waiters[id] = (continuation, t)
    }

    private func expireWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.0.resume(throwing: LGError.notConnected)
    }

    private func resumeWaiters(_ error: Error?) {
        let all = waiters.values
        waiters.removeAll()
        for (c, t) in all {
            t.cancel()
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    // MARK: - State

    private func setState(_ s: ConnectionState) {
        state = s
        stateOut.sendIfChanged(s)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension SSAPEngine {
    /// Debug/testing: kills the live socket as if the network dropped (triggers auto-reconnect).
    func simulateDrop() async {
        await socketDidFailForTesting()
    }
}
