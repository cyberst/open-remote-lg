import Foundation
import Darwin

/// SSDP (UPnP discovery) for webOS TVs.
///
/// * Multicast M-SEARCH to 239.255.255.250 finds every TV at once, but on iOS 14+ it needs the
///   `com.apple.developer.networking.multicast` entitlement; without it `sendto` fails and we silently give up.
/// * Unicast M-SEARCH to `<ip>:1900` needs no entitlement. We use it to identify a TV found by Bonjour or the
///   subnet sweep, so every discovery path yields the same stable id (the UPnP UUID).
enum SSDP {
    static let webOSSearchTarget = "urn:lge-com:service:webos-second-screen:1"
    static let multicastGroup: UInt32 = 0xEFFF_FFFA // 239.255.255.250

    struct Response: Sendable, Equatable {
        var ip: UInt32
        var uuid: String?        // lower-cased, without the "uuid:" prefix
        var location: String?
        var server: String?
        var searchTarget: String?

        var isWebOSSecondScreen: Bool {
            searchTarget?.caseInsensitiveCompare(SSDP.webOSSearchTarget) == .orderedSame
        }
    }

    static func searchMessage(host: String, target: String = webOSSearchTarget, mx: Int = 1) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: \(host):1900\r\nMAN: \"ssdp:discover\"\r\nMX: \(mx)\r\nST: \(target)\r\n\r\n"
    }

    /// Parses an M-SEARCH response or NOTIFY datagram.
    static func parse(_ data: Data, from ip: UInt32) -> Response? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 200") || first.hasPrefix("NOTIFY") else { return nil }
        lines.removeFirst()
        let headers = HTTPResponse.parseHeaders(lines)
        let st = headers["st"] ?? headers["nt"]
        return Response(ip: ip, uuid: headers["usn"].flatMap(uuid(fromUSN:)), location: headers["location"],
                        server: headers["server"], searchTarget: st)
    }

    /// "uuid:9af5…::urn:lge-com:…" → "9af5…"
    static func uuid(fromUSN usn: String) -> String? {
        let lower = usn.lowercased()
        guard lower.hasPrefix("uuid:") else { return nil }
        let rest = lower.dropFirst(5)
        let id = rest.components(separatedBy: "::").first ?? ""
        return id.isEmpty ? nil : String(id)
    }

    /// Sends M-SEARCH to `destination` (a unicast TV address or the multicast group) at each of `sendTimes`
    /// (seconds from start) and reports webOS second-screen responses until `timeout` or until `onResponse`
    /// returns true. Returns false if nothing could be sent (e.g. iOS without the multicast entitlement). Blocking.
    @discardableResult
    static func search(destination: UInt32, timeout: TimeInterval, sendTimes: [TimeInterval] = [0],
                       interface: IPv4Interface? = nil, isCancelled: () -> Bool = { false },
                       onResponse: (Response) -> Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        NetIO.setNonBlocking(fd)
        let isMulticast = destination == multicastGroup
        if isMulticast {
            var ttl: UInt8 = 2
            _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
            if let interface {
                var addr = in_addr(s_addr: interface.address.bigEndian)
                _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
            }
        }
        let message = Array(searchMessage(host: NetIO.ipv4String(destination)).utf8)
        var dest = NetIO.sockaddrIn(destination, port: 1900)
        let start = Date()
        var pendingSends = sendTimes.sorted()
        var sentAny = false
        var buf = [UInt8](repeating: 0, count: 4096)

        while !isCancelled() {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= timeout { break }
            while let t = pendingSends.first, t <= elapsed {
                pendingSends.removeFirst()
                let n = withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if n == message.count { sentAny = true }
            }
            if !sentAny && pendingSends.isEmpty { return false }
            let nextSend = pendingSends.first.map { $0 - elapsed } ?? timeout
            let wait = max(0.001, min(0.1, timeout - elapsed, nextSend))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(wait * 1000)) > 0 else { continue }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let r = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
            }
            guard r > 0 else { continue }
            let ip = UInt32(bigEndian: from.sin_addr.s_addr)
            if !isMulticast && ip != destination { continue }
            if let response = parse(Data(buf[0..<r]), from: ip), response.isWebOSSecondScreen, onResponse(response) { break }
        }
        return sentAny
    }

    /// Unicast M-SEARCH to one host; returns its webOS second-screen response (TVs answer in ~20 ms). Blocking.
    static func unicastProbe(_ ip: UInt32, timeout: TimeInterval = 1.0) -> Response? {
        var found: Response?
        search(destination: ip, timeout: timeout, sendTimes: [0, 0.35]) { found = $0; return true }
        return found
    }
}

/// Fields from a UPnP device description (`LOCATION` XML).
struct UPnPDescription: Sendable, Equatable {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var modelNumber: String?
    var udn: String?

    /// Parses the root device's fields (the first occurrence of each, which is the root device).
    static func parse(_ data: Data) -> UPnPDescription? {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        let f = delegate.fields
        let d = UPnPDescription(friendlyName: f["friendlyName"], manufacturer: f["manufacturer"], modelName: f["modelName"],
                                modelNumber: f["modelNumber"], udn: f["UDN"])
        return d == UPnPDescription() ? nil : d
    }

    /// Fetches the description at `location`, but only from `ip` itself — a LOCATION pointing anywhere else is
    /// ignored so discovery never talks to anything except the TV.
    static func fetch(location: String, expectedIP ip: UInt32, timeout: TimeInterval = 1.5) -> UPnPDescription? {
        guard let url = URL(string: location), url.scheme?.lowercased() == "http",
              let host = url.host, NetIO.parseIPv4(host) == ip else { return nil }
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? "")
        guard let response = NetIO.httpGet(ip, port: UInt16(url.port ?? 80), path: path, timeout: timeout),
              response.status == 200 else { return nil }
        return parse(response.body)
    }

    private final class Collector: NSObject, XMLParserDelegate {
        static let wanted: Set<String> = ["friendlyName", "manufacturer", "modelName", "modelNumber", "UDN"]
        var fields: [String: String] = [:]
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            current = Self.wanted.contains(name) && fields[name] == nil ? name : nil
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if current != nil { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == current {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { fields[name] = value }
            }
            current = nil
        }
    }
}
