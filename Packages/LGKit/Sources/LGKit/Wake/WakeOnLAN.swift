import Foundation
import Darwin

/// Wake-on-LAN for LG TVs. The TV must have "Turn on via Wi‑Fi" / "Mobile TV On" enabled.
///
/// Broadcast destinations need the multicast entitlement on iOS 14+; until we have it those sends fail and only
/// the unicast packet (to the TV's last known address, which works while the router still has its ARP entry)
/// gets out. Nothing here throws: failures are simply "not sent".
public enum WakeOnLAN {
    /// Diagnostics hook (the app sets it in debug builds). Called with one line per send attempt.
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?

    /// The 102-byte magic packet: 6 × 0xFF followed by the MAC repeated 16 times.
    public static func magicPacket(for mac: String) -> [UInt8]? {
        guard let bytes = MACAddress.bytes(mac) else { return nil }
        return [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }
    }

    /// Sends magic packets for every MAC to 255.255.255.255, the Wi‑Fi subnet broadcast and `lastKnownHost`,
    /// on ports 9 and 7, three times over ~1 s. Returns true if at least one packet was sent.
    @discardableResult
    public static func wake(macAddresses: [String], lastKnownHost: String?) async -> Bool {
        var seen = Set<String>()
        let packets = macAddresses.compactMap { mac -> [UInt8]? in
            guard MACAddress.isUsable(mac), let n = MACAddress.normalized(mac), seen.insert(n).inserted else { return nil }
            return magicPacket(for: n)
        }
        guard !packets.isEmpty else { return false }
        let targets = await NetIO.background { destinations(lastKnownHost: lastKnownHost) }
        log?("WoL macs=\(macAddresses) host=\(lastKnownHost ?? "nil") targets=\(targets.ips.count) iface=\(targets.interface ?? "nil")")
        var sentAny = false
        for round in 0..<3 {
            if round > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            if Task.isCancelled { break }
            let sent = await NetIO.background { send(packets, to: targets.ips, boundTo: targets.interface) }
            sentAny = sentAny || sent
        }
        return sentAny
    }

    /// Wakes `device` and waits until its SSAP port answers: re-sends WoL every ~3 s and polls reachability
    /// every ~0.5 s until `timeout`. Returns true once the TV is reachable (also immediately if it already is).
    public static func wakeAndWait(device: TVDevice, timeout: TimeInterval = 20) async -> Bool {
        await wakeAndWait(device: device, timeout: timeout, isReachable: { await TVReachability.isReachable(host: $0, timeout: 0.7) },
                          sendWake: { await wake(macAddresses: $0, lastKnownHost: $1) })
    }

    static func wakeAndWait(device: TVDevice, timeout: TimeInterval,
                            isReachable: @escaping @Sendable (String) async -> Bool,
                            sendWake: @escaping @Sendable ([String], String?) async -> Bool,
                            resendInterval: TimeInterval = 3, pollInterval: TimeInterval = 0.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let host = device.host
        if await isReachable(host) { return true }
        var lastWake = Date.distantPast
        while Date() < deadline, !Task.isCancelled {
            if Date().timeIntervalSince(lastWake) >= resendInterval {
                lastWake = Date()
                // Don't let the ~1 s send loop delay the first reachability poll.
                let macs = device.macAddresses
                Task { _ = await sendWake(macs, host) }
            }
            if await isReachable(host) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(min(pollInterval, remaining) * 1_000_000_000))
        }
        return false
    }

    // MARK: - Sending

    struct Destinations: Sendable { var ips: [UInt32]; var interface: String? }

    static func destinations(lastKnownHost: String?) -> Destinations {
        let lan = NetworkInterfaces.primaryLAN()
        var ips: [UInt32] = [0xFFFF_FFFF]
        if let lan { ips.append(lan.broadcast) }
        if let host = lastKnownHost?.trimmingCharacters(in: .whitespaces), !host.isEmpty, let ip = NetIO.resolveIPv4(host) {
            ips.append(ip)
        }
        var unique: [UInt32] = []
        for ip in ips where !unique.contains(ip) { unique.append(ip) }
        return Destinations(ips: unique, interface: lan?.name)
    }

    /// One round: every packet to every destination on ports 9 and 7. Blocking but instant (UDP).
    static func send(_ packets: [[UInt8]], to ips: [UInt32], boundTo interface: String?) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        NetIO.setIntOption(fd, SOL_SOCKET, SO_BROADCAST, 1)
        // Keep 255.255.255.255 on Wi‑Fi rather than cellular/VPN.
        if let interface, case let index = if_nametoindex(interface), index != 0 {
            NetIO.setIntOption(fd, IPPROTO_IP, IP_BOUND_IF, Int32(index))
        }
        var sentAny = false
        for ip in ips {
            for port: UInt16 in [9, 7] {
                var addr = NetIO.sockaddrIn(ip, port: port)
                for packet in packets {
                    let n = withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    if n == packet.count { sentAny = true }
                    if let log {
                        let dest = "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255):\(port)"
                        log(n == packet.count ? "WoL sent → \(dest) via \(interface ?? "default")"
                                              : "WoL FAILED → \(dest): errno \(errno) \(String(cString: strerror(errno)))")
                    }
                }
            }
        }
        return sentAny
    }
}
