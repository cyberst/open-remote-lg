import Foundation
import XCTest
@testable import LGKit

/// In-process fake of a webOS TV speaking SSAP over a fake WebSocket transport.
final class FakeTV: WebSocketTransportFactory, @unchecked Sendable {
    enum Reply { case payload(JSON), error(String), noReply }
    enum Pairing { case accept(after: TimeInterval), deny(after: TimeInterval), never }
    enum KeyRejection { case prompt, error }

    private let lock = NSLock()
    // Configuration
    var refusedPorts: Set<Int> = []
    var reachable = true
    var validKeys: Set<String> = []
    var pairing: Pairing = .accept(after: 0.02)
    var keyRejection: KeyRejection = .prompt
    var issuedKey = "NEWKEY"
    var expectedPIN = "1234"
    var answersPings = true
    var handlers: [String: (JSON?) -> Reply] = [:]

    // Observations
    private(set) var received: [JSON] = []
    private(set) var pointerFrames: [String] = []
    private(set) var openedURLs: [URL] = []
    private var mainSockets: [FakeSocket] = []
    private var subscriptions: [(socket: FakeSocket, id: String, uri: String)] = []
    private var pendingPIN: [(socket: FakeSocket, registerID: String)] = []

    init() {
        handlers["ssap://com.webos.service.networkinput/getPointerInputSocket"] = { _ in
            .payload(["socketPath": "ws://tv.test:3000/resources/abc/netinput.pointer.sock", "returnValue": true])
        }
        handlers["ssap://audio/getVolume"] = { _ in .payload(["volume": 3, "muted": false, "scenario": "mastervolume_tv_speaker", "returnValue": true]) }
    }

    func makeTransport(url: URL) -> WebSocketTransport { FakeSocket(tv: self, url: url) }

    // MARK: Helpers for tests

    func set(_ uri: String, _ reply: @escaping (JSON?) -> Reply) { lock.withLock { handlers[uri] = reply } }

    var receivedMessages: [JSON] { lock.withLock { received } }
    var frames: [String] { lock.withLock { pointerFrames } }
    var opened: [URL] { lock.withLock { openedURLs } }
    func messages(uri: String) -> [JSON] { receivedMessages.filter { $0["uri"]?.stringValue == uri } }
    func registerMessages() -> [JSON] { receivedMessages.filter { $0["type"]?.stringValue == "register" } }

    /// Server-side close of every main SSAP socket (like the TV going away / Wi-Fi dropping).
    func dropConnections() {
        let socks = lock.withLock { () -> [FakeSocket] in
            let s = mainSockets; mainSockets.removeAll(); subscriptions.removeAll(); return s
        }
        socks.forEach { $0.serverClose() }
    }

    /// Pushes a subscription event to every live subscriber of `uri`.
    func push(_ uri: String, _ payload: JSON) {
        let targets = lock.withLock { subscriptions.filter { $0.uri == uri && !$0.socket.isClosed } }
        for t in targets { t.socket.deliver(["type": "response", "id": .string(t.id), "payload": payload]) }
    }

    func liveSubscriptionCount(uri: String) -> Int {
        lock.withLock { subscriptions.filter { $0.uri == uri && !$0.socket.isClosed }.count }
    }

    // MARK: Transport callbacks

    fileprivate func canOpen(_ socket: FakeSocket) -> Bool {
        lock.withLock {
            openedURLs.append(socket.url)
            guard reachable, !refusedPorts.contains(socket.url.port ?? 0) else { return false }
            if !socket.isPointer { mainSockets.append(socket) }
            return true
        }
    }

    fileprivate func receivedPointerFrame(_ frame: String) { lock.withLock { pointerFrames.append(frame) } }

    fileprivate func handle(_ text: String, from socket: FakeSocket) {
        guard let msg = try? JSON.parse(Data(text.utf8)) else { return }
        lock.withLock { received.append(msg) }
        let id = msg["id"]?.stringValue ?? ""
        switch msg["type"]?.stringValue {
        case "register": handleRegister(msg, id: id, socket: socket)
        case "request", "subscribe":
            let uri = msg["uri"]?.stringValue ?? ""
            if uri == "ssap://pairing/setPin" { handlePIN(msg, id: id, socket: socket); return }
            if msg["type"]?.stringValue == "subscribe" { lock.withLock { subscriptions.append((socket, id, uri)) } }
            let handler = lock.withLock { handlers[uri] }
            let reply = handler?(msg["payload"]) ?? .error("404 no such service or method")
            switch reply {
            case .payload(let p): socket.deliver(["type": "response", "id": .string(id), "payload": p])
            case .error(let e): socket.deliver(["type": "error", "id": .string(id), "error": .string(e), "payload": [:]])
            case .noReply: break
            }
        default: break
        }
    }

    private func handleRegister(_ msg: JSON, id: String, socket: FakeSocket) {
        let p = msg["payload"]
        let key = p?["client-key"]?.stringValue
        if let key, lock.withLock({ validKeys.contains(key) }) {
            socket.deliver(["type": "registered", "id": .string(id), "payload": ["client-key": .string(key)]])
            return
        }
        if key != nil, keyRejection == .error {
            socket.deliver(["type": "error", "id": .string(id), "error": "401 invalid client key", "payload": [:]])
            return
        }
        let wantsPIN = p?["pairingType"]?.stringValue == "PIN"
        socket.deliver(["type": "response", "id": .string(id), "payload": ["pairingType": .string(wantsPIN ? "PIN" : "PROMPT"), "returnValue": true]])
        if wantsPIN { lock.withLock { pendingPIN.append((socket, id)) }; return }
        switch pairing {
        case .accept(let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.issueKey(to: socket, id: id) }
        case .deny(let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                socket.deliver(["type": "error", "id": .string(id), "error": "403 User denied access", "payload": [:]])
            }
        case .never: break
        }
    }

    private func handlePIN(_ msg: JSON, id: String, socket: FakeSocket) {
        let pin = msg["payload"]?["pin"]?.stringValue
        guard let entry = lock.withLock({ pendingPIN.first { $0.socket === socket } }) else { return }
        if pin == expectedPIN {
            socket.deliver(["type": "response", "id": .string(id), "payload": ["returnValue": true]])
            issueKey(to: socket, id: entry.registerID)
        } else {
            socket.deliver(["type": "error", "id": .string(id), "error": "500 Application error", "payload": ["returnValue": false, "errorText": "Wrong PIN"]])
        }
    }

    private func issueKey(to socket: FakeSocket, id: String) {
        let key = lock.withLock { () -> String in validKeys.insert(issuedKey); return issuedKey }
        socket.deliver(["type": "registered", "id": .string(id), "payload": ["client-key": .string(key)]])
    }
}

final class FakeSocket: WebSocketTransport, @unchecked Sendable {
    let url: URL
    private weak var tv: FakeTV?
    private let lock = NSLock()
    private var closed = false
    private var opened = false
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var iterator: AsyncStream<String>.Iterator

    var isPointer: Bool { url.path.contains("pointer") }
    var isClosed: Bool { lock.withLock { closed } }

    init(tv: FakeTV, url: URL) {
        self.tv = tv; self.url = url
        var c: AsyncStream<String>.Continuation!
        stream = AsyncStream { c = $0 }
        continuation = c
        iterator = stream.makeAsyncIterator()
    }

    func open(timeout: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 2_000_000)
        guard let tv, tv.canOpen(self) else { throw LGError.network("Connection refused") }
        lock.withLock { opened = true }
    }

    func send(_ text: String) async throws {
        guard lock.withLock({ opened && !closed }) else { throw LGError.network("closed") }
        if isPointer { tv?.receivedPointerFrame(text); return }
        tv?.handle(text, from: self)
    }

    func receive() async throws -> String {
        guard let next = await iterator.next() else { throw LGError.network("closed") }
        return next
    }

    func ping(timeout: TimeInterval) async throws {
        guard !isClosed, tv?.answersPings ?? false else { throw LGError.timeout }
    }

    func close() {
        lock.withLock { closed = true }
        continuation.finish()
    }

    func serverClose() { close() }

    func deliver(_ msg: JSON) {
        guard !isClosed, let data = try? msg.data() else { return }
        continuation.yield(String(decoding: data, as: UTF8.self))
    }
}

/// Records every state a client goes through.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ConnectionState] = []
    private var task: Task<Void, Never>?

    init(_ client: TVControlling) {
        let stream = client.observeState()
        task = Task { [weak self] in for await s in stream { self?.append(s) } }
    }
    deinit { task?.cancel() }

    private func append(_ s: ConnectionState) { lock.withLock { states.append(s) } }
    var all: [ConnectionState] { lock.withLock { states } }

    func waitFor(_ timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                 _ predicate: (ConnectionState) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let last = all.last, predicate(last) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for state; got \(all)", file: file, line: line)
    }
}

extension SSAPTiming {
    static let fast = SSAPTiming(connectTimeout: 0.5, requestTimeout: 0.5, pairingTimeout: 2, pingInterval: 30, pingTimeout: 0.2,
                                 backoff: [0.01, 0.02, 0.04], maxReconnectAttempts: 4, secureHeadStart: 0.02,
                                 preferredHeadStart: 0.02)
}

func makeClient(_ tv: FakeTV, keys: InMemoryKeyStore = InMemoryKeyStore(), secure: Bool? = nil,
                timing: SSAPTiming = .fast) -> LGTVClient {
    let device = TVDevice(id: "tv1", name: "", host: "tv.test", useSecureSocket: secure)
    return LGTVClient(device: device, keyStore: keys, factory: tv, timing: timing, log: nil, prewarmPointer: false)
}

func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
