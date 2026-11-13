import XCTest
import Foundation
@testable import LGKit

/// Manual real-TV harness, skipped unless `LGKIT_MEDIA_HARNESS_DIR` is set.
///
///     LGKIT_MEDIA_HARNESS_DIR=/path/with/media LGKIT_MEDIA_HARNESS_PEER=192.168.178.250 \
///     LGKIT_MEDIA_HARNESS_SECONDS=90 swift test --filter MediaServerTVHarnessTests
///
/// Serves every .jpg/.png/.mp4/.mov in the directory on the LAN, writes `urls.json` (name → URL) into it,
/// then keeps serving and appends one line per response to `access.log` there. Drive the TV from another shell, e.g.
/// `tools/tv.py media.viewer/open '{"target": "<url>", "mimeType": "image/jpeg"}'`.
final class MediaServerTVHarnessTests: XCTestCase {
    func testServeDirectoryToTV() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["LGKIT_MEDIA_HARNESS_DIR"] else { throw XCTSkip("set LGKIT_MEDIA_HARNESS_DIR to run") }
        let seconds = Double(env["LGKIT_MEDIA_HARNESS_SECONDS"] ?? "") ?? 60
        let dir = URL(fileURLWithPath: dirPath)
        let server = MediaServer(peer: env["LGKIT_MEDIA_HARNESS_PEER"])
        let started = Date()
        let logURL = dir.appendingPathComponent("access.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        server.accessLog = { e in
            let t = String(format: "%7.2f", Date().timeIntervalSince(started))
            let line = "[\(t)s] \(e.peer) \(e.method) \(e.path.suffix(24)) range=\(e.range ?? "-") -> \(e.status) bytes=\(e.bytesSent) ua=\(e.userAgent ?? "-")\n"
            log.write(Data(line.utf8)) // unbuffered so a second shell can `tail -f` it
        }
        let base = try await server.start()
        let mimes = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "mp4": "video/mp4", "mov": "video/quicktime"]
        var urls: [String: String] = [:]
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            guard let mime = mimes[f.pathExtension.lowercased()] else { continue }
            urls[f.lastPathComponent] = try server.register(fileURL: f, mimeType: mime).absoluteString
        }
        try JSONSerialization.data(withJSONObject: urls, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("urls.json"))
        print("[harness] serving \(urls.count) files at \(base) for \(Int(seconds))s")
        if let tvHost = env["LGKIT_MEDIA_HARNESS_DLNA"] {
            try await castViaDLNA(host: tvHost, urls: urls, mimes: mimes, log: log)
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        server.stop()
        print("[harness] stopped")
    }

    /// `LGKIT_MEDIA_HARNESS_DLNA=<tv ip>`: casts each served file through `DLNARenderer` (~8 s each), then stops.
    private func castViaDLNA(host: String, urls: [String: String], mimes: [String: String], log: FileHandle) async throws {
        func note(_ s: String) { log.write(Data("[dlna] \(s)\n".utf8)) }
        let found = await DLNARenderer.discover(host: host)
        let renderer = try XCTUnwrap(found, "no DLNA renderer on \(host)")
        note("renderer \(renderer.friendlyName ?? "?") at \(renderer.controlURL)")
        for name in urls.keys.sorted() {
            guard let s = urls[name], let url = URL(string: s), let mime = mimes[url.pathExtension.lowercased()] else { continue }
            do {
                try await renderer.load(url: url, mimeType: mime, title: name)
                try await Task.sleep(for: .seconds(mime.hasPrefix("video/") ? 9 : 6))
                let info = try await renderer.transportInfo()
                note("\(name) \(mime): state=\(info.state) position=\(info.position.map { "\($0)" } ?? "-") duration=\(info.duration.map { "\($0)" } ?? "-")")
            } catch {
                note("\(name) \(mime): ERROR \(error.localizedDescription)")
            }
        }
        try? await renderer.stop()
        note("stopped")
    }
}
