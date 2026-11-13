import XCTest
import Foundation
import Network
@testable import LGKit

final class MediaDLNATests: XCTestCase {
    static let deviceXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>[LG] webOS TV SM8000PLA</friendlyName>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
            <controlURL>/ConnectionManager/x/control.xml</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
            <controlURL>/AVTransport/643cad83/control.xml</controlURL>
          </service>
        </serviceList>
      </device>
    </root>
    """

    func testParsesDeviceDescription() throws {
        let d = try XCTUnwrap(DeviceDescription.parse(Data(Self.deviceXML.utf8)))
        XCTAssertEqual(d.friendlyName, "[LG] webOS TV SM8000PLA")
        XCTAssertEqual(d.avTransportControlURL, "/AVTransport/643cad83/control.xml")
        XCTAssertNil(DeviceDescription.parse(Data("not xml <".utf8)))
    }

    func testEnvelopeAndDIDLAreEscaped() {
        let url = URL(string: "http://192.168.1.2:5000/abc/a&b.jpg")!
        let didl = DLNARenderer.didl(url: url, mimeType: "image/jpeg", title: "Tom & Jerry <3>")
        XCTAssertTrue(didl.contains("<dc:title>Tom &amp; Jerry &lt;3&gt;</dc:title>"))
        XCTAssertTrue(didl.contains("object.item.imageItem.photo"))
        XCTAssertTrue(didl.contains("http-get:*:image/jpeg:"))
        XCTAssertTrue(didl.contains(">http://192.168.1.2:5000/abc/a&amp;b.jpg</res>"))
        XCTAssertTrue(DLNARenderer.didl(url: url, mimeType: "video/mp4", title: "v").contains("object.item.videoItem"))

        let env = DLNARenderer.envelope(action: "SetAVTransportURI", args: [("InstanceID", "0"), ("CurrentURIMetaData", didl)])
        XCTAssertTrue(env.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        XCTAssertTrue(env.contains("<CurrentURIMetaData>&lt;DIDL-Lite"), "metadata is embedded as escaped text")
        XCTAssertFalse(env.contains("<CurrentURIMetaData><DIDL"))
        // Round trip: what the renderer unescapes is the original DIDL.
        XCTAssertEqual(DLNARenderer.tag("CurrentURIMetaData", in: env), didl)
    }

    func testTagAndTimeHelpers() {
        let xml = "<s:Body><u:GetPositionInfoResponse><Track>1</Track><TrackDuration>0:01:05</TrackDuration><RelTime>00:00:07.500</RelTime></u:GetPositionInfoResponse>"
        XCTAssertEqual(DLNARenderer.tag("TrackDuration", in: xml), "0:01:05")
        XCTAssertEqual(DLNARenderer.tag("RelTime", in: xml).flatMap(DLNARenderer.parseTime), 7.5)
        XCTAssertEqual(DLNARenderer.tag("errorCode", in: "<s:Fault><detail><UPnPError><errorCode>701</errorCode></UPnPError></detail>"), "701")
        XCTAssertNil(DLNARenderer.tag("Missing", in: xml))
        XCTAssertNil(DLNARenderer.parseTime("NOT_IMPLEMENTED"))
        XCTAssertEqual(DLNARenderer.formatTime(3725), "01:02:05")
        XCTAssertEqual(DLNARenderer.formatTime(-3), "00:00:00")
    }

    func testTransportInfoStates() {
        XCTAssertTrue(DLNARenderer.TransportInfo(state: "PLAYING").isPlaying)
        XCTAssertTrue(DLNARenderer.TransportInfo(state: "PAUSED_PLAYBACK").isPaused)
        XCTAssertFalse(DLNARenderer.TransportInfo(state: "PAUSED_PLAYBACK").isPlaying)
        XCTAssertFalse(DLNARenderer.TransportInfo(state: "LG_TRANSITIONING").isPlaying)
    }

    func testSSDPLocationParsing() {
        let r = "HTTP/1.1 200 OK\r\nCache-Control: max-age=1800\r\nLocation: http://192.168.178.250:1106/\r\nST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n"
        XCTAssertEqual(RendererSSDP.location(in: r), URL(string: "http://192.168.178.250:1106/"))
        XCTAssertNil(RendererSSDP.location(in: "HTTP/1.1 200 OK\r\n\r\n"))
    }

    func testMiniHTTPParsing() throws {
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(try XCTUnwrap(MiniHTTP.parse(chunked)).text, "hello world")
        let sized = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabcdef".utf8)
        let r = try XCTUnwrap(MiniHTTP.parse(sized))
        XCTAssertEqual(r.status, 404); XCTAssertEqual(r.text, "abc")
        XCTAssertTrue(MiniHTTP.isComplete(sized))
        XCTAssertFalse(MiniHTTP.isComplete(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)))
        XCTAssertNil(MiniHTTP.parse(Data("garbage".utf8)))
    }

    func testMiniHTTPAgainstMediaServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MediaDLNATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("hello media".utf8).write(to: file)
        let server = MediaServer(advertisedHost: "127.0.0.1")
        defer { server.stop() }
        try await server.start()
        let url = try server.register(fileURL: file, mimeType: "text/plain")
        let r = try await MiniHTTP.send("GET", url: url)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.text, "hello media")
        XCTAssertEqual(r.headers["content-type"], "text/plain")
    }

    func testRendererAgainstFakeTV() async throws {
        let fake = try await FakeRenderer.start(description: Self.deviceXML)
        defer { fake.stop() }
        let found = await DLNARenderer.renderer(descriptionURL: fake.url("/"))
        let renderer = try XCTUnwrap(found)
        XCTAssertEqual(renderer.friendlyName, "[LG] webOS TV SM8000PLA")
        XCTAssertEqual(renderer.controlURL, fake.url("/AVTransport/643cad83/control.xml"))

        try await renderer.load(url: URL(string: "http://10.0.0.2:1234/tok/p.jpg")!, mimeType: "image/jpeg", title: "Photo")
        let info = try await renderer.transportInfo()
        XCTAssertEqual(info.state, "PLAYING")
        XCTAssertEqual(info.position, 7)
        XCTAssertEqual(info.duration, 65)

        let actions = fake.requests.map(\.action)
        XCTAssertEqual(actions, ["", "SetAVTransportURI", "Play", "GetTransportInfo", "GetPositionInfo"])
        XCTAssertTrue(fake.requests[1].body.contains("<CurrentURI>http://10.0.0.2:1234/tok/p.jpg</CurrentURI>"))

        do { try await renderer.seek(to: 5); XCTFail("fault should throw") } catch let e as LGError {
            XCTAssertEqual(e, .tvError("Seek: Seek mode not supported (710)"))
        }
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable { weak var value: T? }

/// A tiny HTTP server pretending to be the TV's DLNA renderer.
final class FakeRenderer: @unchecked Sendable {
    struct Request { var action: String; var body: String }
    private let listener: NWListener
    private let lock = NSLock()
    private var _requests: [Request] = []
    private let description: String
    let port: UInt16
    var requests: [Request] { lock.withLock { _requests } }

    private init(listener: NWListener, port: UInt16, description: String) {
        self.listener = listener; self.port = port; self.description = description
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }

    static func start(description: String) async throws -> FakeRenderer {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "FakeRenderer")
        let owner = WeakBox<FakeRenderer>()
        listener.newConnectionHandler = { c in // must be set before start()
            c.start(queue: queue)
            owner.value?.read(c, Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { s in
                if case .ready = s, once.claim() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                if case .failed(let e) = s, once.claim() { cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
        let fake = FakeRenderer(listener: listener, port: port, description: description)
        owner.value = fake
        return fake
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer; if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { if !done { self.read(c, buf) }; return }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            let len = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            guard buf.count - end.upperBound >= len else { if !done { self.read(c, buf) }; return }
            let body = String(decoding: buf[end.upperBound..<(end.upperBound + len)], as: UTF8.self)
            let action = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("soapaction:") }
                .flatMap { $0.split(separator: "#").last }.map { $0.replacingOccurrences(of: "\"", with: "") } ?? ""
            self.lock.withLock { self._requests.append(Request(action: action, body: body)) }
            let (status, reply) = self.reply(action)
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/xml\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n\(reply)"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func reply(_ action: String) -> (String, String) {
        func ok(_ inner: String) -> (String, String) {
            ("200 OK", "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>")
        }
        switch action {
        case "": return ("200 OK", description)
        case "GetTransportInfo": return ok("<CurrentTransportState>PLAYING</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus>")
        case "GetPositionInfo": return ok("<TrackDuration>00:01:05</TrackDuration><RelTime>00:00:07</RelTime>")
        case "Seek":
            return ("500 Internal Server Error", "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><faultcode>s:Client</faultcode><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>710</errorCode><errorDescription>Seek mode not supported</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>")
        default: return ok("")
        }
    }
}
