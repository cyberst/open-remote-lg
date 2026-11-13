import Foundation
import Darwin

/// Small blocking BSD-socket helpers shared by discovery, reachability and Wake-on-LAN.
/// Everything here blocks for at most its `timeout`; call it through `NetIO.background` from async code.
///
/// Plain sockets are used on purpose: they allow unconnected UDP (SSDP replies come from a different port than
/// the one we sent to), poll()-based port scanning with hundreds of in-flight connects on one thread, and plain
/// HTTP to LAN addresses without depending on App Transport Security exceptions.
enum NetIO {
    /// Runs blocking work on a utility-QoS GCD thread so it never blocks the main actor or the cooperative pool.
    static func background<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
        }
    }

    // MARK: Addresses (IPv4 addresses are passed around as host-order UInt32)

    static func parseIPv4(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func ipv4String(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    static func sockaddrIn(_ ip: UInt32, port: UInt16) -> sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: ip.bigEndian)
        return sa
    }

    /// Resolves a dotted quad or hostname (incl. `.local` via mDNS) to IPv4. Blocking.
    static func resolveIPv4(_ host: String) -> UInt32? {
        if let ip = parseIPv4(host) { return ip }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            p = ai.pointee.ai_next
        }
        return nil
    }

    // MARK: Socket utilities

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setIntOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var v = value
        _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    static func socketError(_ fd: Int32) -> Int32 {
        var e: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &len)
        return e
    }

    /// Starts a non-blocking TCP connect. Returns the fd and the immediate result of `connect()`.
    static func startConnect(_ ip: UInt32, port: UInt16) -> (fd: Int32, errno: Int32)? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        setNonBlocking(fd)
        setIntOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        var sa = sockaddrIn(ip, port: port)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return (fd, r == 0 ? 0 : errno)
    }

    enum ConnectOutcome: Equatable { case open, refused, unreachable }

    /// Connects with a timeout. On `.open` the returned fd is connected (non-blocking) and owned by the caller.
    static func connect(_ ip: UInt32, port: UInt16, timeout: TimeInterval) -> (ConnectOutcome, Int32?) {
        guard let (fd, e) = startConnect(ip, port: port) else { return (.unreachable, nil) }
        if e == 0 { return (.open, fd) }
        guard e == EINPROGRESS else { close(fd); return (e == ECONNREFUSED ? .refused : .unreachable, nil) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let n = poll(&pfd, 1, ms)
            if n < 0, errno == EINTR, deadline.timeIntervalSinceNow > 0 { continue }
            guard n > 0 else { close(fd); return (.unreachable, nil) }
            break
        }
        let err = socketError(fd)
        if err == 0 { return (.open, fd) }
        close(fd)
        return (err == ECONNREFUSED ? .refused : .unreachable, nil)
    }

    static func isPortOpen(_ ip: UInt32, port: UInt16, timeout: TimeInterval) -> Bool {
        let (outcome, fd) = connect(ip, port: port, timeout: timeout)
        if let fd { close(fd) }
        return outcome == .open
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: Date) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; continue }
            guard n < 0, errno == EAGAIN || errno == EINTR else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ms = Int32(deadline.timeIntervalSinceNow * 1000)
            guard ms > 0, poll(&pfd, 1, ms) > 0 else { return false }
        }
        return true
    }

    /// Minimal plain-HTTP GET (HTTP/1.0, `Connection: close`). Returns the parsed response, or nil on any failure.
    static func httpGet(_ ip: UInt32, port: UInt16, path: String, timeout: TimeInterval, limit: Int = 256 * 1024) -> HTTPResponse? {
        let deadline = Date().addingTimeInterval(timeout)
        let (outcome, maybeFD) = connect(ip, port: port, timeout: timeout)
        guard outcome == .open, let fd = maybeFD else { return nil }
        defer { close(fd) }
        let request = "GET \(path) HTTP/1.0\r\nHost: \(ipv4String(ip)):\(port)\r\nConnection: close\r\nAccept: */*\r\n\r\n"
        guard writeAll(fd, Array(request.utf8), deadline: deadline) else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let ms = Int32(deadline.timeIntervalSinceNow * 1000)
            guard ms > 0 else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, ms)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            let r = read(fd, &buf, buf.count)
            if r < 0, errno == EAGAIN || errno == EINTR { continue }
            guard r > 0 else { break }
            data.append(buf, count: r)
        }
        return HTTPResponse(raw: data)
    }
}

/// A parsed HTTP response (status line, lower-cased headers, de-chunked body).
struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init?(raw: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator),
              let head = String(data: raw[..<range.lowerBound], encoding: .utf8) ?? String(data: raw[..<range.lowerBound], encoding: .isoLatin1)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let code = Int(statusLine[1]) else { return nil }
        status = code
        headers = Self.parseHeaders(lines)
        let rawBody = Data(raw[range.upperBound...])
        body = headers["transfer-encoding"]?.lowercased().contains("chunked") == true ? Self.dechunk(rawBody) : rawBody
    }

    var bodyText: String { String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self) }

    static func parseHeaders(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, headers[key] == nil { headers[key] = value }
        }
        return headers
    }

    /// Best-effort chunked decoding; returns whatever was decodable on malformed input.
    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex, let lineEnd = data.range(of: crlf, in: i..<data.endIndex) {
            let sizeField = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
