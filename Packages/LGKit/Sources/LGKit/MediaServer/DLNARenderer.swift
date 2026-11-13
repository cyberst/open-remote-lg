import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Controls a TV's built-in DLNA/UPnP MediaRenderer (AVTransport) — the path LG TVs reliably fetch
/// LAN media from. On the 2019 webOS 4.5 test TV, SSAP `media.viewer/open` reported success but never
/// requested the URL, while `SetAVTransportURI` + `Play` loaded photos, H.264 and HEVC MP4s.
public final class DLNARenderer: Sendable {
    public let controlURL: URL
    public let friendlyName: String?

    public init(controlURL: URL, friendlyName: String? = nil) {
        self.controlURL = controlURL; self.friendlyName = friendlyName
    }

    public struct TransportInfo: Sendable, Hashable {
        /// e.g. PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING, NO_MEDIA_PRESENT (LG prefixes some with "LG_").
        public var state: String
        /// Elapsed / total seconds, when the renderer reports them.
        public var position: TimeInterval?
        public var duration: TimeInterval?

        public var isPlaying: Bool { state.hasSuffix("PLAYING") && !state.contains("PAUSED") }
        public var isPaused: Bool { state.contains("PAUSED") }
    }

    // MARK: Discovery

    /// Finds the MediaRenderer on `host` with a unicast RendererSSDP search (no multicast entitlement needed),
    /// falling back to LG's usual description port. Returns nil if the TV has no usable renderer.
    public static func discover(host: String, timeout: TimeInterval = 2) async -> DLNARenderer? {
        var locations = await Task.detached { RendererSSDP.search(host: host, timeout: timeout) }.value
        let fallback = URL(string: "http://\(host):1106/")
        if let fallback, !locations.contains(fallback) { locations.append(fallback) }
        for location in locations {
            if let r = await renderer(descriptionURL: location) { return r }
        }
        return nil
    }

    public static func renderer(descriptionURL: URL) async -> DLNARenderer? {
        guard let resp = try? await MiniHTTP.send("GET", url: descriptionURL, timeout: 3), resp.status == 200,
              let parsed = DeviceDescription.parse(resp.body),
              let path = parsed.avTransportControlURL,
              let control = URL(string: path, relativeTo: parsed.urlBase.flatMap(URL.init(string:)) ?? descriptionURL)?.absoluteURL
        else { return nil }
        return DLNARenderer(controlURL: control, friendlyName: parsed.friendlyName)
    }

    // MARK: Transport

    /// Loads a photo or video and starts it.
    public func load(url: URL, mimeType: String, title: String) async throws {
        let meta = Self.didl(url: url, mimeType: mimeType, title: title)
        try await call("SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", meta)])
        try await play()
    }

    public func play() async throws { try await call("Play", [("InstanceID", "0"), ("Speed", "1")]) }
    public func pause() async throws { try await call("Pause", [("InstanceID", "0")]) }
    public func stop() async throws { try await call("Stop", [("InstanceID", "0")]) }

    public func seek(to seconds: TimeInterval) async throws {
        try await call("Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.formatTime(seconds))])
    }

    public func transportInfo() async throws -> TransportInfo {
        let t = try await call("GetTransportInfo", [("InstanceID", "0")])
        var info = TransportInfo(state: Self.tag("CurrentTransportState", in: t) ?? "UNKNOWN")
        if let p = try? await call("GetPositionInfo", [("InstanceID", "0")]) {
            info.position = Self.tag("RelTime", in: p).flatMap(Self.parseTime)
            info.duration = Self.tag("TrackDuration", in: p).flatMap(Self.parseTime)
        }
        return info
    }

    /// The first load cold-starts the TV's player app; LG answers these only once it is up (~5 s measured).
    static let slowActions: Set<String> = ["SetAVTransportURI", "Play", "Stop"]

    @discardableResult
    func call(_ action: String, _ args: [(String, String)]) async throws -> String {
        let body = Self.envelope(action: action, args: args)
        let resp = try await MiniHTTP.send("POST", url: controlURL, headers: [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPACTION": "\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"",
        ], body: Data(body.utf8), timeout: Self.slowActions.contains(action) ? 15 : 6)
        let text = resp.text
        guard resp.status == 200 else {
            let code = Self.tag("errorCode", in: text) ?? "\(resp.status)"
            let desc = Self.tag("errorDescription", in: text) ?? "request failed"
            throw LGError.tvError("\(action): \(desc) (\(code))")
        }
        return text
    }

    // MARK: Encoding helpers

    static func envelope(action: String, args: [(String, String)]) -> String {
        let inner = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(inner)</u:\(action)></s:Body></s:Envelope>"
    }

    /// DIDL-Lite metadata; LG's renderer picks the photo viewer vs video player from `upnp:class`.
    static func didl(url: URL, mimeType: String, title: String) -> String {
        let cls: String
        if mimeType.hasPrefix("image/") { cls = "object.item.imageItem.photo" }
        else if mimeType.hasPrefix("audio/") { cls = "object.item.audioItem.musicTrack" }
        else { cls = "object.item.videoItem" }
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(xmlEscape(title))</dc:title><upnp:class>\(cls)</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(xmlEscape(mimeType)):DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\">"
            + "\(xmlEscape(url.absoluteString))</res></item></DIDL-Lite>"
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""; out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Value of the first `<name>` element (namespace prefix tolerated), XML-unescaped.
    static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<(?:[A-Za-z0-9_]+:)?\(name)(?:\\s[^>]*)?>", options: .regularExpression),
              let close = xml.range(of: "</(?:[A-Za-z0-9_]+:)?\(name)>", options: .regularExpression, range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// Parses H+:MM:SS[.fff]; nil for NOT_IMPLEMENTED and similar.
    static func parseTime(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - Device description

struct DeviceDescription {
    var friendlyName: String?
    var urlBase: String?
    var avTransportControlURL: String?

    static func parse(_ data: Data) -> DeviceDescription? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = DeviceDescription()
        private var text = ""
        private var serviceType: String?
        private var controlURL: String?
        private var inService = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "service" { inService = true; serviceType = nil; controlURL = nil }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "friendlyName" where result.friendlyName == nil: result.friendlyName = value
            case "URLBase": result.urlBase = value
            case "serviceType" where inService: serviceType = value
            case "controlURL" where inService: controlURL = value
            case "service":
                inService = false
                if result.avTransportControlURL == nil, serviceType?.contains(":service:AVTransport:") == true {
                    result.avTransportControlURL = controlURL
                }
            default: break
            }
            text = ""
        }
    }
}

// MARK: - RendererSSDP

enum RendererSSDP {
    /// Sends a unicast M-SEARCH for AVTransport to `host`:1900 and returns the LOCATION URLs it answers with.
    /// Blocking; call off the main thread.
    static func search(host: String, timeout: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return [] }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n"
        let bytes = Array(msg.utf8)
        func sendOnce() {
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bytes.withUnsafeBufferPointer { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        sendOnce()
        var found: [URL] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var resent = false
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 {
                if !resent { resent = true; sendOnce() } // UDP may drop the first datagram
                continue
            }
            if let url = location(in: String(decoding: buf[0..<n], as: UTF8.self)), !found.contains(url) {
                found.append(url)
                break
            }
        }
        return found
    }

    static func location(in response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location"
            else { continue }
            return URL(string: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
