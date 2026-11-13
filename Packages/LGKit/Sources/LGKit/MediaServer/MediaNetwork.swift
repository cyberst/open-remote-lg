import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Local IPv4 addresses, used to build a URL the TV can reach.
public enum MediaNetwork {
    public struct IPv4: Sendable, Hashable {
        public var name: String
        public var address: String
        /// Host-order address and netmask, for subnet matching.
        public var rawAddress: UInt32
        public var rawNetmask: UInt32

        public func contains(_ other: String) -> Bool {
            guard let raw = MediaNetwork.parseIPv4(other) else { return false }
            return raw & rawNetmask == rawAddress & rawNetmask
        }
    }

    /// All up, non-loopback IPv4 interfaces.
    public static func ipv4Interfaces() -> [IPv4] {
        var result: [IPv4] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(IPv4(name: String(cString: ifa.ifa_name), address: format(a), rawAddress: a, rawNetmask: m))
        }
        return result
    }

    /// The best local IPv4 address for serving media to `peer` (the TV's host):
    /// the interface on the TV's subnet, else Wi‑Fi (`en0`), else any other Ethernet-like interface.
    /// Link-local (169.254/16) addresses are used only as a last resort.
    public static func localIPv4(towards peer: String? = nil, interfaces: [IPv4] = ipv4Interfaces()) -> String? {
        if let peer, parseIPv4(peer) != nil, let match = interfaces.first(where: { $0.contains(peer) }) {
            return match.address
        }
        let routable = interfaces.filter { $0.rawAddress >> 16 != 0xA9FE }
        if let wifi = routable.first(where: { $0.name == "en0" }) { return wifi.address }
        if let other = routable.first(where: { $0.name.hasPrefix("en") || $0.name.hasPrefix("bridge") }) { return other.address }
        return routable.first?.address ?? interfaces.first?.address
    }

    static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard let octet = UInt8(p) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}
