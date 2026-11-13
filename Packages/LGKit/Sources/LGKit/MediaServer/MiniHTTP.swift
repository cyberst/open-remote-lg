import Foundation
import Network

/// Minimal one-shot HTTP/1.1 client over Network.framework, for talking to the TV's DLNA renderer.
/// Uses raw TCP (not URLSession) so plain-http LAN requests aren't subject to App Transport Security.
enum MiniHTTP {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] // lower-cased names
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    static let maxResponseBytes = 1 << 20

    static func send(_ method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                     timeout: TimeInterval = 8) async throws -> Response {
        guard url.scheme == "http", let host = url.host, !host.isEmpty else { throw LGError.network("Unsupported URL \(url)") }
        let port = UInt16(url.port ?? 80)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LGError.network("Bad port") }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?\(q)" }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nUser-Agent: OpenRemote\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        let payload = Data(head.utf8) + (body ?? Data())

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "LGKit.MiniHTTP")
        let raw: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = Once()
                let received = Buffer() // only touched on `queue`
                func finish(_ result: Result<Data, Error>) {
                    guard once.claim() else { return }
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    cont.resume(with: result)
                }
                func receive() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                        if let data { received.data.append(data) }
                        if received.data.count > maxResponseBytes { finish(.failure(LGError.network("Response too large"))); return }
                        if complete || error != nil || Self.isComplete(received.data) { finish(.success(received.data)); return }
                        receive()
                    }
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: payload, completion: .contentProcessed { error in
                            if let error { finish(.failure(LGError.network(error.localizedDescription))) } else { receive() }
                        })
                    case .failed(let e), .waiting(let e): finish(.failure(LGError.network(e.localizedDescription)))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(LGError.timeout)) }
                conn.start(queue: queue)
            }
        } onCancel: { conn.cancel() }
        guard let response = parse(raw) else { throw LGError.network("Malformed HTTP response") }
        return response
    }

    /// True once a full Content-Length body has arrived (servers that keep the socket open despite `Connection: close`).
    static func isComplete(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        guard let line = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }),
              let len = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else { return false }
        return data.count - end.upperBound >= len
    }

    static func parse(_ data: Data) -> Response? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        else if let len = headers["content-length"].flatMap(Int.init), body.count > len { body = body.prefix(len) }
        return Response(status: code, headers: headers, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data(); var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while let lineEnd = data.range(of: crlf, in: i..<data.endIndex) {
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            guard let stop = data.index(start, offsetBy: size, limitedBy: data.endIndex) else { out.append(data[start...]); break }
            out.append(data[start..<stop])
            i = min(data.endIndex, stop + 2)
        }
        return out
    }
}

final class Buffer: @unchecked Sendable { var data = Data() }

/// Thread-safe "first caller wins" flag.
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
