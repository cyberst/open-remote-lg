import Foundation
import Network

/// A tiny HTTP/1.1 file server for casting local photos and videos to a TV on the LAN.
///
/// * Serves only files registered with `register(fileURL:mimeType:fileName:)`, each under an unguessable
///   random-token path (`/<32 hex chars>/<name>`); everything else is 404.
/// * GET and HEAD, single byte ranges (206/416), keep-alive, concurrent connections.
/// * Streams from disk in fixed-size chunks and waits for each chunk to be sent before reading the next,
///   so memory stays bounded no matter how large the file or how many range requests a TV fires.
///
/// Thread-safe. Start on demand, stop when casting ends.
public final class MediaServer: @unchecked Sendable {
    public struct AccessLogEntry: Sendable, Hashable {
        public var method: String
        public var path: String
        public var range: String?
        public var status: Int
        /// Body bytes actually sent.
        public var bytesSent: Int64
        public var peer: String
        public var userAgent: String?
    }

    public enum ServerError: Error, LocalizedError, Equatable {
        case noNetworkAddress
        case notRunning
        case fileNotFound
        case listenerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noNetworkAddress: "Connect your device to the same Wi‑Fi network as your TV to cast."
            case .notRunning: "The casting server is not running."
            case .fileNotFound: "The file to cast could not be found."
            case .listenerFailed(let m): "Could not start casting: \(m)"
            }
        }
    }

    struct Resource {
        let fileURL: URL
        let mimeType: String
        let size: Int64
    }

    /// Called (on a background queue) after every response. Set before `start()`.
    public var accessLog: (@Sendable (AccessLogEntry) -> Void)? {
        get { lock.withLock { _accessLog } }
        set { lock.withLock { _accessLog = newValue } }
    }

    let chunkSize: Int
    let maxConnections: Int
    let idleTimeout: TimeInterval
    private let advertisedHost: String?
    private let peerHint: String?
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "LGKit.MediaServer.listener")
    private var listener: NWListener?
    private var _baseURL: URL?
    private var _accessLog: (@Sendable (AccessLogEntry) -> Void)?
    private var resources: [String: Resource] = [:]
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// - Parameters:
    ///   - advertisedHost: host to put in URLs (e.g. "127.0.0.1" in tests). nil = detect the LAN IPv4 at start.
    ///   - peer: the TV's host, used to pick the interface on the TV's subnet when detecting.
    public init(advertisedHost: String? = nil, peer: String? = nil, chunkSize: Int = 128 * 1024,
                maxConnections: Int = 32, idleTimeout: TimeInterval = 30) {
        self.advertisedHost = advertisedHost; self.peerHint = peer
        self.chunkSize = chunkSize; self.maxConnections = maxConnections; self.idleTimeout = idleTimeout
    }

    deinit { listener?.cancel(); connections.values.forEach { $0.cancel() } }

    public var baseURL: URL? { lock.withLock { _baseURL } }
    public var isRunning: Bool { baseURL != nil }
    public var connectionCount: Int { lock.withLock { connections.count } }

    /// Starts listening on an ephemeral port (no-op if already running). Returns the base URL.
    @discardableResult
    public func start() async throws -> URL {
        if let url = baseURL { return url }
        guard let host = advertisedHost ?? MediaNetwork.localIPv4(towards: peerHint) else { throw ServerError.noNetworkAddress }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params, on: .any) } catch { throw ServerError.listenerFailed(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: ServerError.listenerFailed(error.localizedDescription)) }
                    else { self?.listenerDied(listener) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: ServerError.notRunning) }
                default: break
                }
            }
            listener.start(queue: listenerQueue)
        }
        guard port != 0, let url = URL(string: "http://\(host):\(port)") else {
            listener.cancel(); throw ServerError.listenerFailed("no port")
        }
        let winner: URL = lock.withLock {
            if let existing = _baseURL { return existing } // lost a start() race; keep the first listener
            self.listener = listener; _baseURL = url; return url
        }
        if winner != url { listener.cancel() }
        return winner
    }

    /// Stops listening, drops all connections and forgets every registered file.
    public func stop() {
        let (l, cs) = lock.withLock { () -> (NWListener?, [HTTPConnection]) in
            defer { listener = nil; _baseURL = nil; resources.removeAll(); connections.removeAll() }
            return (listener, Array(connections.values))
        }
        l?.cancel()
        cs.forEach { $0.cancel() }
    }

    /// Makes `fileURL` downloadable and returns its full URL. The server must be running.
    @discardableResult
    public func register(fileURL: URL, mimeType: String, fileName: String? = nil) throws -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attrs?[.size] as? NSNumber)?.int64Value else { throw ServerError.fileNotFound }
        let token = Self.randomToken()
        let name = Self.sanitize(fileName ?? fileURL.lastPathComponent)
        return try lock.withLock {
            guard let base = _baseURL else { throw ServerError.notRunning }
            resources[token] = Resource(fileURL: fileURL, mimeType: mimeType, size: size)
            return base.appendingPathComponent(token).appendingPathComponent(name)
        }
    }

    /// Stops serving a URL returned by `register`.
    public func unregister(_ url: URL) {
        let comps = url.pathComponents.filter { $0 != "/" }
        guard let token = comps.first else { return }
        lock.withLock { _ = resources.removeValue(forKey: token) }
    }

    public func unregisterAll() { lock.withLock { resources.removeAll() } }

    // MARK: - Internals

    func resource(forPath path: String) -> Resource? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count == 2 else { return nil }
        return lock.withLock { resources[String(comps[0])] }
    }

    func log(_ entry: AccessLogEntry) { accessLog?(entry) }

    func connectionClosed(_ c: HTTPConnection) { lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(c)) } }

    private func accept(_ nw: NWConnection) {
        let c = HTTPConnection(connection: nw, server: self)
        let accepted = lock.withLock { () -> Bool in
            guard listener != nil, connections.count < maxConnections else { return false }
            connections[ObjectIdentifier(c)] = c
            return true
        }
        if accepted { c.start() } else { nw.cancel() }
    }

    private func listenerDied(_ l: NWListener?) {
        let mine = lock.withLock { listener != nil && listener === l }
        if mine { stop() }
    }

    static func randomToken() -> String {
        var g = SystemRandomNumberGenerator() // arc4random-backed: cryptographically secure on Apple platforms
        return (0..<2).map { _ in String(format: "%016llx", g.next() as UInt64) }.joined()
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "media" : cleaned
    }
}
