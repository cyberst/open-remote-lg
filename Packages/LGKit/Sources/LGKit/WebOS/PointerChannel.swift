import Foundation

/// The webOS pointer-input socket (buttons, mouse moves, clicks, scroll). Opened lazily, reopened on failure.
/// Mouse moves are coalesced to ~60 Hz so fast touchpad input never queues up behind the network.
actor PointerChannel {
    typealias URLProvider = @Sendable () async throws -> URL

    private let factory: WebSocketTransportFactory
    private let urlProvider: URLProvider
    private let connectTimeout: TimeInterval
    private let minMoveInterval: TimeInterval
    private let log: (@Sendable (String) -> Void)?

    private var socket: WebSocketTransport?
    private var opening: Task<WebSocketTransport, Error>?
    private var epoch = 0

    private var pendingDX = 0.0, pendingDY = 0.0, pendingDrag = false
    private var flushing = false
    private var lastMove = Date.distantPast

    init(factory: WebSocketTransportFactory, connectTimeout: TimeInterval, minMoveInterval: TimeInterval = 1.0 / 60,
         log: (@Sendable (String) -> Void)? = nil, urlProvider: @escaping URLProvider) {
        self.factory = factory; self.urlProvider = urlProvider; self.connectTimeout = connectTimeout
        self.minMoveInterval = minMoveInterval; self.log = log
    }

    // MARK: Frames

    static func buttonFrame(_ name: String) -> String { "type:button\nname:\(name)\n\n" }
    static func moveFrame(dx: Int, dy: Int, down: Bool) -> String { "type:move\ndx:\(dx)\ndy:\(dy)\ndown:\(down ? 1 : 0)\n\n" }
    static let clickFrame = "type:click\n\n"
    static func scrollFrame(dx: Int, dy: Int) -> String { "type:scroll\ndx:\(dx)\ndy:\(dy)\n\n" }

    // MARK: API

    func button(_ name: String) async throws {
        try await flushMoves()
        try await send(Self.buttonFrame(name))
    }

    func click() async throws {
        try await flushMoves()
        try await send(Self.clickFrame)
    }

    func scroll(dx: Double, dy: Double) async throws {
        try await flushMoves()
        let x = Int(dx.rounded()), y = Int(dy.rounded())
        guard x != 0 || y != 0 else { return }
        try await send(Self.scrollFrame(dx: x, dy: y))
    }

    /// Accumulates the delta. Whoever arrives while no flush is running drives the flush loop; everyone else
    /// returns immediately, so callers never wait behind a slow network.
    func move(dx: Double, dy: Double, drag: Bool) async throws {
        pendingDX += dx; pendingDY += dy; pendingDrag = drag
        guard !flushing else { return }
        try await flushMoves()
    }

    /// Drops the socket, e.g. after the main SSAP connection was re-established (old pointer URLs die with it).
    func reset() {
        epoch += 1 // an open still in flight belongs to the old connection; ensureOpen discards it
        opening?.cancel(); opening = nil
        socket?.close(); socket = nil
    }

    /// Opens the socket ahead of the first button press.
    func prewarm() async {
        _ = try? await ensureOpen()
    }

    // MARK: Internals

    private func flushMoves() async throws {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while true {
            let x = pendingDX.rounded(.towardZero), y = pendingDY.rounded(.towardZero)
            if x == 0 && y == 0 { return }
            let wait = minMoveInterval - Date().timeIntervalSince(lastMove)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            // Re-read after the sleep: more movement may have accumulated meanwhile.
            let sx = pendingDX.rounded(.towardZero), sy = pendingDY.rounded(.towardZero)
            pendingDX -= sx; pendingDY -= sy // keep sub-pixel remainders
            lastMove = Date()
            do {
                try await send(Self.moveFrame(dx: Int(sx), dy: Int(sy), down: pendingDrag))
            } catch {
                pendingDX = 0; pendingDY = 0
                throw error
            }
        }
    }

    private func send(_ frame: String) async throws {
        let sock = try await ensureOpen()
        do {
            try await sock.send(frame)
        } catch {
            // Stale socket (TV dropped it, app was suspended…): reopen once and retry.
            log?("pointer send failed (\(error)); reopening")
            if socket === sock { socket = nil }
            sock.close()
            let fresh = try await ensureOpen()
            try await fresh.send(frame)
        }
    }

    private func ensureOpen() async throws -> WebSocketTransport {
        if let socket { return socket }
        if let opening { return try await opening.value }
        let myEpoch = epoch
        let task = Task { () throws -> WebSocketTransport in try await self.openNew() }
        opening = task
        let sock: WebSocketTransport
        do { sock = try await task.value } catch {
            if epoch == myEpoch { opening = nil }
            throw error
        }
        guard epoch == myEpoch else {
            // reset() ran while we were opening: this socket is for the old connection. Don't store it (that
            // would leak whatever a newer open stores) and don't touch the newer `opening`. Retry on the new one.
            sock.close()
            try Task.checkCancellation()
            return try await ensureOpen()
        }
        opening = nil
        if let existing = socket, existing !== sock { existing.close() }
        socket = sock
        return sock
    }

    private func openNew() async throws -> WebSocketTransport {
        let url = try await urlProvider()
        do {
            let s = factory.makeTransport(url: url)
            try await s.open(timeout: connectTimeout)
            return s
        } catch {
            // Some firmware returns a ws:3000 path while only wss:3001 is reachable (or vice versa).
            guard let alt = Self.alternateURL(url) else { throw error }
            log?("pointer socket \(url) failed (\(error)); trying \(alt)")
            let s = factory.makeTransport(url: alt)
            try await s.open(timeout: connectTimeout)
            return s
        }
    }

    static func alternateURL(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch (c.scheme, c.port) {
        case ("ws", 3000): c.scheme = "wss"; c.port = 3001
        case ("wss", 3001): c.scheme = "ws"; c.port = 3000
        default: return nil
        }
        return c.url
    }
}
