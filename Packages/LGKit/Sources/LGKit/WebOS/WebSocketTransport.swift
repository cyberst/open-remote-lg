import Foundation

// MARK: - Transport abstraction (internal, so unit tests can inject a fake TV)

/// One text-frame WebSocket connection.
protocol WebSocketTransport: AnyObject, Sendable {
    /// Opens the socket. Returns once the handshake completed; throws on failure or after `timeout`.
    func open(timeout: TimeInterval) async throws
    func send(_ text: String) async throws
    /// Next text message. Throws once the socket is closed.
    func receive() async throws -> String
    /// Round-trip ping; throws if no pong arrives within `timeout`.
    func ping(timeout: TimeInterval) async throws
    func close()
}

protocol WebSocketTransportFactory: Sendable {
    func makeTransport(url: URL) -> WebSocketTransport
}

// MARK: - URLSession implementation

struct URLSessionTransportFactory: WebSocketTransportFactory {
    func makeTransport(url: URL) -> WebSocketTransport { URLSessionWebSocketTransport(url: url) }
}

/// `URLSessionWebSocketTask` wrapper. Accepts the TV's self-signed certificate, but only for the exact host
/// we are connecting to (webOS TVs serve a self-signed / expired LG certificate on port 3001).
final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closed = false

    init(url: URL) { self.url = url }

    func open(timeout: TimeInterval) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024 // app lists with metadata can exceed the 1 MB default
        lock.withLock { self.session = session; self.task = task }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let alreadyClosed = self.lock.withLock { () -> Bool in
                        if self.closed { return true }
                        self.openContinuation = c
                        return false
                    }
                    if alreadyClosed { c.resume(throwing: LGError.network("Socket closed")) } else { task.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LGError.timeout
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                self.close()
                throw error
            }
        }
    }

    func send(_ text: String) async throws {
        guard let task = lock.withLock({ task }) else { throw LGError.notConnected }
        do { try await task.send(.string(text)) } catch { throw LGError.network(error.localizedDescription) }
    }

    func receive() async throws -> String {
        guard let task = lock.withLock({ task }) else { throw LGError.notConnected }
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { throw LGError.network(error.localizedDescription) }
            switch message {
            case .string(let s): return s
            case .data(let d): if let s = String(data: d, encoding: .utf8) { return s }
            @unknown default: continue
            }
        }
    }

    func ping(timeout: TimeInterval) async throws {
        guard let task = lock.withLock({ task }) else { throw LGError.notConnected }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error { c.resume(throwing: LGError.network(error.localizedDescription)) } else { c.resume() }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LGError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func close() {
        let (task, session, cont) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?, CheckedContinuation<Void, Error>?) in
            closed = true
            let r = (self.task, self.session, openContinuation)
            openContinuation = nil
            return r
        }
        cont?.resume(throwing: LGError.network("Socket closed"))
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finishOpen(_ error: Error?) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = openContinuation; openContinuation = nil; return c
        }
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finishOpen(nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finishOpen(LGError.network("Socket closed (\(closeCode.rawValue))"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finishOpen(LGError.network(error?.localizedDescription ?? "Socket closed"))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host.caseInsensitiveCompare(url.host ?? "") == .orderedSame,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
