import Foundation
import Darwin

/// An IPv4 address on a local interface (host byte order).
struct IPv4Interface: Sendable, Equatable {
    var name: String
    var address: UInt32
    var netmask: UInt32
    var broadcast: UInt32 { address | ~netmask }
    var prefixLength: Int { netmask.nonzeroBitCount }
}

enum NetworkInterfaces {
    /// All up, running, non-loopback IPv4 interfaces.
    static func ipv4() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let nm = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(IPv4Interface(name: String(cString: ifa.pointee.ifa_name), address: ip, netmask: nm))
        }
        return result
    }

    /// The LAN interface a TV is most likely on: en0 (Wi-Fi on iPhone/iPad), else another `en*`, ignoring
    /// link-local, cellular (pdp_ip), VPN (utun/ipsec) and peer-to-peer (awdl/llw) interfaces.
    static func primaryLAN(from interfaces: [IPv4Interface] = ipv4()) -> IPv4Interface? {
        let lan = interfaces.filter { $0.name.hasPrefix("en") && $0.address >> 16 != 0xA9FE && $0.prefixLength < 31 }
        return lan.first { $0.name == "en0" } ?? lan.first
    }
}

enum SubnetSweep {
    /// Hosts to probe on `interface`'s subnet, excluding our own address, the network and the broadcast address.
    /// Subnets larger than `cap` hosts are narrowed to the largest block around our own address that fits.
    static func hosts(for interface: IPv4Interface, cap: Int = 1024) -> [UInt32] {
        var hostBits = min(24, 32 - interface.prefixLength)
        while hostBits > 1, (1 << hostBits) - 2 > cap { hostBits -= 1 }
        guard hostBits >= 2 else { return [] }
        let mask: UInt32 = ~((1 << UInt32(hostBits)) - 1)
        let network = interface.address & mask
        let broadcast = network | ~mask
        return (network + 1 ..< broadcast).filter { $0 != interface.address }
    }

    /// Scans `targets` with non-blocking connects, at most `window` in flight, each bounded by `timeout`.
    /// Reports every target's outcome as soon as it is known. Runs on the calling thread (one thread for the whole scan).
    static func scan(_ targets: [(ip: UInt32, port: UInt16)], timeout: TimeInterval, window: Int,
                     isCancelled: () -> Bool, onResult: (_ index: Int, _ outcome: NetIO.ConnectOutcome) -> Void) {
        struct Pending { var fd: Int32; var index: Int; var deadline: Date }
        var pending: [Pending] = []
        var next = 0
        while (next < targets.count || !pending.isEmpty) && !isCancelled() {
            while pending.count < window, next < targets.count {
                let index = next; next += 1
                guard let (fd, e) = NetIO.startConnect(targets[index].ip, port: targets[index].port) else {
                    onResult(index, .unreachable); continue
                }
                if e == EINPROGRESS {
                    pending.append(Pending(fd: fd, index: index, deadline: Date().addingTimeInterval(timeout)))
                } else {
                    close(fd)
                    onResult(index, e == 0 ? .open : e == ECONNREFUSED ? .refused : .unreachable)
                }
            }
            guard !pending.isEmpty else { continue }
            var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            let soonest = pending.map(\.deadline).min() ?? Date()
            // Cap the wait so cancellation is noticed promptly.
            let ms = Int32(min(100, max(1, soonest.timeIntervalSinceNow * 1000)))
            _ = poll(&fds, nfds_t(fds.count), ms)
            let now = Date()
            var stillPending: [Pending] = []
            for (i, item) in pending.enumerated() {
                if fds[i].revents != 0 {
                    let err = NetIO.socketError(item.fd)
                    close(item.fd)
                    onResult(item.index, err == 0 ? .open : err == ECONNREFUSED ? .refused : .unreachable)
                } else if item.deadline <= now {
                    close(item.fd)
                    onResult(item.index, .unreachable)
                } else {
                    stillPending.append(item)
                }
            }
            pending = stillPending
        }
        pending.forEach { close($0.fd) }
    }

    /// Two-phase webOS sweep: TCP 3000 on every host, then TCP 3001 only on hosts that actively refused 3000
    /// (they exist, but may be newer TVs with only the secure port open). Calls `onCandidate` for every host with
    /// either port open. A /24 takes ~(254 / window) × timeout ≈ 1.6 s with the defaults.
    static func findWebOSCandidates(hosts: [UInt32], timeout: TimeInterval = 0.4, window: Int = 64,
                                    isCancelled: () -> Bool, onCandidate: (_ ip: UInt32, _ openPort: UInt16) -> Void) {
        var refused: [UInt32] = []
        scan(hosts.map { ($0, UInt16(3000)) }, timeout: timeout, window: window, isCancelled: isCancelled) { i, outcome in
            switch outcome {
            case .open: onCandidate(hosts[i], 3000)
            case .refused: refused.append(hosts[i])
            case .unreachable: break
            }
        }
        guard !refused.isEmpty, !isCancelled() else { return }
        scan(refused.map { ($0, UInt16(3001)) }, timeout: timeout, window: window, isCancelled: isCancelled) { i, outcome in
            if outcome == .open { onCandidate(refused[i], 3001) }
        }
    }
}
