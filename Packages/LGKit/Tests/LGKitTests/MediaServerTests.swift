import XCTest
import Foundation
@testable import LGKit

final class MediaServerTests: XCTestCase {
    private var server: MediaServer!
    private var dir: URL!
    private var file: URL!
    private var content: Data!
    private var session: URLSession!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 1 MB + odd tail so chunk boundaries are exercised; deterministic bytes so slices can be compared.
        content = Data((0..<(1_048_576 + 4_321)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        file = dir.appendingPathComponent("clip.mp4")
        try content.write(to: file)
        server = MediaServer(advertisedHost: "127.0.0.1", chunkSize: 64 * 1024)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        server.stop()
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: dir)
    }

    private func get(_ url: URL, range: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let (data, resp) = try await session.data(for: req)
        return (data, try XCTUnwrap(resp as? HTTPURLResponse))
    }

    func testStartReturnsBaseURLAndRegisterBuildsTokenURL() async throws {
        let base = try await server.start()
        XCTAssertEqual(base.host, "127.0.0.1")
        XCTAssertNotEqual(base.port ?? 0, 0)
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let comps = url.pathComponents.filter { $0 != "/" }
        XCTAssertEqual(comps.count, 2)
        XCTAssertEqual(comps[0].count, 32, "token must be 128-bit hex")
        XCTAssertEqual(comps[1], "clip.mp4")
        let again = try server.register(fileURL: file, mimeType: "video/mp4")
        XCTAssertNotEqual(url, again, "each registration gets a fresh token")
        let restart = try await server.start()
        XCTAssertEqual(restart, base, "start is idempotent")
    }

    func testRegisterBeforeStartThrows() {
        XCTAssertThrowsError(try server.register(fileURL: file, mimeType: "video/mp4")) {
            XCTAssertEqual($0 as? MediaServer.ServerError, .notRunning)
        }
    }

    func testRegisterMissingFileThrows() async throws {
        try await server.start()
        XCTAssertThrowsError(try server.register(fileURL: dir.appendingPathComponent("nope.jpg"), mimeType: "image/jpeg"))
    }

    func testFullGet() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (data, resp) = try await get(url)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Length"), "\(content.count)")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(data, content)
    }

    func testHead() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "image/jpeg")
        let (data, resp) = try await get(url, method: "HEAD")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Length"), "\(content.count)")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertTrue(data.isEmpty)
    }

    func testClosedRange() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (data, resp) = try await get(url, range: "bytes=100-65635")
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes 100-65635/\(content.count)")
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Length"), "65536")
        XCTAssertEqual(data, content.subdata(in: 100..<65636))
    }

    func testOpenEndedRange() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let start = content.count - 70_000
        let (data, resp) = try await get(url, range: "bytes=\(start)-")
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes \(start)-\(content.count - 1)/\(content.count)")
        XCTAssertEqual(data, content.subdata(in: start..<content.count))
    }

    func testSuffixRange() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (data, resp) = try await get(url, range: "bytes=-500")
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes \(content.count - 500)-\(content.count - 1)/\(content.count)")
        XCTAssertEqual(data, content.suffix(500))
    }

    func testRangeEndBeyondSizeIsClamped() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (data, resp) = try await get(url, range: "bytes=\(content.count - 10)-99999999")
        XCTAssertEqual(resp.statusCode, 206)
        XCTAssertEqual(data, content.suffix(10))
    }

    func testUnsatisfiableRange() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (_, resp) = try await get(url, range: "bytes=\(content.count)-")
        XCTAssertEqual(resp.statusCode, 416)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Content-Range"), "bytes */\(content.count)")
    }

    func testUnknownTokenAndPathsAre404() async throws {
        let base = try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let token = url.pathComponents[1]
        for path in ["/", "/clip.mp4", "/\(String(repeating: "0", count: 32))/clip.mp4", "/\(token)", "/\(token)/x/y", "/../etc/passwd"] {
            let (_, resp) = try await get(URL(string: base.absoluteString + path)!)
            XCTAssertEqual(resp.statusCode, 404, path)
        }
        server.unregister(url)
        let (_, resp) = try await get(url)
        XCTAssertEqual(resp.statusCode, 404, "unregistered files are no longer served")
    }

    func testOtherMethodsRejected() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let (_, resp) = try await get(url, method: "DELETE")
        XCTAssertEqual(resp.statusCode, 405)
    }

    func testConcurrentRangeRequests() async throws {
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let size = content.count
        let ranges: [(Int, Int)] = (0..<24).map { i in
            let start = (i * 45_007) % (size - 1)
            return (start, min(size - 1, start + 100_000 + i * 1_000))
        }
        try await withThrowingTaskGroup(of: (Int, Data, Int).self) { group in
            for (i, r) in ranges.enumerated() {
                group.addTask {
                    let (d, resp) = try await self.get(url, range: "bytes=\(r.0)-\(r.1)")
                    return (i, d, resp.statusCode)
                }
            }
            for _ in 0..<4 { group.addTask { let (d, resp) = try await self.get(url); return (-1, d, resp.statusCode) } }
            for try await (i, data, status) in group {
                if i < 0 { XCTAssertEqual(status, 200); XCTAssertEqual(data, content); continue }
                XCTAssertEqual(status, 206)
                XCTAssertEqual(data, content.subdata(in: ranges[i].0..<(ranges[i].1 + 1)), "range \(i)")
            }
        }
    }

    func testKeepAlivePipelinedRequestsOnOneSocket() async throws {
        let base = try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        let port = UInt16(try XCTUnwrap(base.port))
        let path = url.path
        let raw = try await Task.detached {
            try RawSocket.exchange(port: port, request:
                "HEAD \(path) HTTP/1.1\r\nHost: x\r\n\r\n" +
                "GET \(path) HTTP/1.1\r\nHost: x\r\nRange: bytes=0-9\r\n\r\n" +
                "GET \(path) HTTP/1.1\r\nHost: x\r\nRange: bytes=10-19\r\nConnection: close\r\n\r\n")
        }.value
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 206 Partial Content").count - 1, 2)
        XCTAssertTrue(text.contains("Content-Range: bytes 0-9/"))
        XCTAssertTrue(text.contains("Content-Range: bytes 10-19/"))
        XCTAssertTrue(raw.range(of: content.subdata(in: 0..<10)) != nil)
        XCTAssertTrue(raw.range(of: content.subdata(in: 10..<20)) != nil)
    }

    func testAccessLogAndStop() async throws {
        let entries = LockedBox<[MediaServer.AccessLogEntry]>([])
        server.accessLog = { e in entries.mutate { $0.append(e) } }
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "video/mp4")
        _ = try await get(url, range: "bytes=0-99")
        try await Task.sleep(for: .milliseconds(100))
        let first = try XCTUnwrap(entries.value.first)
        XCTAssertEqual(first.status, 206)
        XCTAssertEqual(first.bytesSent, 100)
        XCTAssertEqual(first.range, "bytes=0-99")

        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.baseURL)
        do { _ = try await get(url); XCTFail("server should be down") } catch {}
    }

    func testRangeParser() {
        XCTAssertEqual(ByteRangeRequest.parse(nil, size: 10), .full)
        XCTAssertEqual(ByteRangeRequest.parse("bytes=0-4", size: 10), .partial(0...4))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=5-", size: 10), .partial(5...9))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=-3", size: 10), .partial(7...9))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=-30", size: 10), .partial(0...9))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=2-100", size: 10), .partial(2...9))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=0-1, 4-5", size: 10), .partial(0...1))
        XCTAssertEqual(ByteRangeRequest.parse("bytes=10-", size: 10), .unsatisfiable)
        XCTAssertEqual(ByteRangeRequest.parse("bytes=-0", size: 10), .unsatisfiable)
        XCTAssertEqual(ByteRangeRequest.parse("bytes=0-", size: 0), .unsatisfiable)
        XCTAssertEqual(ByteRangeRequest.parse("bytes=5-2", size: 10), .full)
        XCTAssertEqual(ByteRangeRequest.parse("items=0-1", size: 10), .full)
        XCTAssertEqual(ByteRangeRequest.parse("bytes=abc", size: 10), .full)
    }

    func testLocalIPv4Selection() {
        func iface(_ name: String, _ addr: String, _ mask: String) -> MediaNetwork.IPv4 {
            MediaNetwork.IPv4(name: name, address: addr, rawAddress: MediaNetwork.parseIPv4(addr)!,
                                   rawNetmask: MediaNetwork.parseIPv4(mask)!)
        }
        let list = [iface("utun3", "10.8.0.2", "255.255.255.0"), iface("en0", "192.168.178.72", "255.255.255.0"),
                    iface("en5", "172.16.1.4", "255.255.0.0"), iface("en7", "169.254.3.3", "255.255.0.0")]
        XCTAssertEqual(MediaNetwork.localIPv4(towards: "172.16.9.9", interfaces: list), "172.16.1.4")
        XCTAssertEqual(MediaNetwork.localIPv4(towards: "192.168.178.250", interfaces: list), "192.168.178.72")
        XCTAssertEqual(MediaNetwork.localIPv4(towards: "tv.local", interfaces: list), "192.168.178.72")
        XCTAssertEqual(MediaNetwork.localIPv4(interfaces: [list[3], list[2]]), "172.16.1.4")
        XCTAssertNil(MediaNetwork.localIPv4(interfaces: []))
        XCTAssertFalse(MediaNetwork.ipv4Interfaces().contains { $0.address == "127.0.0.1" })
    }

    func testSanitizedFileName() {
        XCTAssertEqual(MediaServer.sanitize("IMG 0001.HEIC"), "IMG-0001.HEIC")
        XCTAssertEqual(MediaServer.sanitize("../x.jpg"), "..-x.jpg")
        XCTAssertEqual(MediaServer.sanitize(".."), "media")
        XCTAssertEqual(MediaServer.sanitize("Ölçü.mp4"), "-l--.mp4")
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

/// Minimal blocking TCP client to check keep-alive / pipelining on a single socket.
enum RawSocket {
    static func exchange(port: UInt16, request: String, timeout: TimeInterval = 5) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { throw URLError(.cannotConnectToHost) }
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
