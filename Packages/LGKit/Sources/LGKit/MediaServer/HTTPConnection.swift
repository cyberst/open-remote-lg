import Foundation
import Network

/// One client connection of `MediaServer`. All state is confined to `queue`.
final class HTTPConnection: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var version: String
        var headers: [String: String] // lower-cased names

        var keepAlive: Bool {
            let c = headers["connection"]?.lowercased() ?? ""
            return version == "HTTP/1.0" ? c.contains("keep-alive") : !c.contains("close")
        }
    }

    static let maxHeaderBytes = 32 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let nw: NWConnection
    private weak var server: MediaServer?
    private let queue = DispatchQueue(label: "LGKit.MediaServer.connection")
    private let chunkSize: Int
    private let idleTimeout: TimeInterval
    private var buffer = Data()
    private var idleTimer: DispatchWorkItem?
    private var closed = false
    private let peer: String

    init(connection: NWConnection, server: MediaServer) {
        self.nw = connection; self.server = server
        self.chunkSize = server.chunkSize; self.idleTimeout = server.idleTimeout
        if case .hostPort(let host, _) = connection.endpoint { peer = "\(host)" } else { peer = "\(connection.endpoint)" }
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        queue.async { self.armIdleTimer(); self.receive() }
    }

    func cancel() { queue.async { self.close() } }

    // MARK: Reading

    private func receive() {
        guard !closed else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.handleBufferedRequest() { return }
            if isComplete || error != nil { self.close(); return }
            if self.buffer.count > Self.maxHeaderBytes {
                self.sendError(431, "Request Header Fields Too Large", keepAlive: false, request: nil); return
            }
            self.receive()
        }
    }

    /// Parses and answers one complete request from `buffer` if there is one. Returns true if it did.
    private func handleBufferedRequest() -> Bool {
        guard let end = buffer.range(of: Self.headerTerminator) else { return false }
        let head = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        idleTimer?.cancel()
        guard let request = Self.parse(head) else {
            sendError(400, "Bad Request", keepAlive: false, request: nil); return true
        }
        // GET/HEAD bodies are meaningless; drop any announced body so it isn't parsed as the next request.
        if let len = request.headers["content-length"].flatMap(Int.init), len > 0 {
            guard len <= buffer.count else { sendError(400, "Bad Request", keepAlive: false, request: request); return true }
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + len))
        }
        respond(to: request)
        return true
    }

    static func parse(_ head: Data) -> Request? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var target = String(requestLine[1])
        if let url = URL(string: target), url.scheme != nil { target = url.path } // absolute-form
        if let q = target.firstIndex(where: { $0 == "?" || $0 == "#" }) { target = String(target[..<q]) }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return Request(method: String(requestLine[0]), path: target.removingPercentEncoding ?? target,
                       version: String(requestLine[2]), headers: headers)
    }

    // MARK: Responding

    private func respond(to request: Request) {
        guard request.method == "GET" || request.method == "HEAD" else {
            sendError(405, "Method Not Allowed", keepAlive: false, request: request, extra: ["Allow": "GET, HEAD"]); return
        }
        guard let server, let resource = server.resource(forPath: request.path) else {
            sendError(404, "Not Found", keepAlive: request.keepAlive, request: request); return
        }
        let size = resource.size
        var headers: [(String, String)] = [
            ("Content-Type", resource.mimeType),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "no-store"),
        ]
        // Some LG/DLNA renderers ask for these; harmless otherwise.
        if request.headers["getcontentfeatures.dlna.org"] != nil {
            headers.append(("contentFeatures.dlna.org", "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"))
        }
        if request.headers["transfermode.dlna.org"] != nil {
            headers.append(("transferMode.dlna.org", resource.mimeType.hasPrefix("image/") ? "Interactive" : "Streaming"))
        }

        let status: Int, reason: String, offset: Int64, length: Int64
        switch ByteRangeRequest.parse(request.headers["range"], size: size) {
        case .full:
            status = 200; reason = "OK"; offset = 0; length = size
        case .partial(let r):
            status = 206; reason = "Partial Content"; offset = r.lowerBound; length = r.upperBound - r.lowerBound + 1
            headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(size)"))
        case .unsatisfiable:
            sendError(416, "Range Not Satisfiable", keepAlive: request.keepAlive, request: request,
                      extra: ["Content-Range": "bytes */\(size)"]); return
        }
        headers.append(("Content-Length", "\(length)"))
        let keepAlive = request.keepAlive
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        let head = Self.head(status: status, reason: reason, headers: headers)

        guard request.method == "GET", length > 0 else {
            nw.send(content: head, completion: .contentProcessed { [weak self] error in
                self?.finish(request: request, status: status, sent: 0, keepAlive: keepAlive && error == nil)
            })
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: resource.fileURL)
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            sendError(404, "Not Found", keepAlive: keepAlive, request: request); return
        }
        nw.send(content: head, completion: .contentProcessed { _ in })
        stream(handle, remaining: length, sent: 0) { [weak self] sent, ok in
            try? handle.close()
            self?.finish(request: request, status: status, sent: sent, keepAlive: keepAlive && ok)
        }
    }

    /// Sends `remaining` bytes from `handle`, one chunk in flight at a time.
    private func stream(_ handle: FileHandle, remaining: Int64, sent: Int64, done: @escaping (Int64, Bool) -> Void) {
        guard !closed else { done(sent, false); return }
        let count = Int(min(Int64(chunkSize), remaining))
        let chunk: Data
        do { chunk = try handle.read(upToCount: count) ?? Data() } catch { done(sent, false); return }
        guard !chunk.isEmpty else { done(sent, false); return } // file shrank underneath us
        nw.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            let total = sent + Int64(chunk.count)
            if error != nil { done(total, false); return }
            let left = remaining - Int64(chunk.count)
            if left > 0 { self.stream(handle, remaining: left, sent: total, done: done) } else { done(total, true) }
        })
    }

    private func sendError(_ status: Int, _ reason: String, keepAlive: Bool, request: Request?, extra: [String: String] = [:]) {
        let body = Data("\(status) \(reason)\n".utf8)
        var headers: [(String, String)] = [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", "\(body.count)"),
                                           ("Connection", keepAlive ? "keep-alive" : "close")]
        headers += extra.sorted { $0.key < $1.key }
        var data = Self.head(status: status, reason: reason, headers: headers)
        if request?.method != "HEAD" { data.append(body) }
        nw.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.finish(request: request, status: status, sent: 0, keepAlive: keepAlive && error == nil)
        })
    }

    private func finish(request: Request?, status: Int, sent: Int64, keepAlive: Bool) {
        if let request, let server {
            server.log(.init(method: request.method, path: request.path, range: request.headers["range"], status: status,
                             bytesSent: sent, peer: peer, userAgent: request.headers["user-agent"]))
        }
        guard keepAlive, !closed else { close(); return }
        armIdleTimer()
        if !handleBufferedRequest() { receive() }
    }

    static func head(status: Int, reason: String, headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status) \(reason)\r\n"
        s += "Date: \(httpDate.string(from: Date()))\r\nServer: OpenRemote\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    // MARK: Lifecycle

    private func armIdleTimer() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel(); idleTimer = nil
        nw.stateUpdateHandler = nil
        nw.cancel()
        server?.connectionClosed(self)
    }
}
