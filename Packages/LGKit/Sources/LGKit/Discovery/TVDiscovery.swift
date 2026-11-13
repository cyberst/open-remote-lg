import Foundation

/// Finds LG webOS TVs on the local network without the multicast entitlement:
///  1. Bonjour (`_airplay._tcp`, `_hap._tcp`) — 2019+ TVs, usually < 0.5 s.
///  2. Unicast subnet sweep of TCP 3000/3001 — any webOS TV, ~1.6 s for a /24.
///  3. Multicast SSDP — all webOS TVs; silently skipped where iOS denies multicast (no entitlement).
/// Every candidate is then identified with a *unicast* SSDP query (no entitlement needed), so a TV gets the same
/// id — its UPnP UUID — whichever path found it.
public final class TVDiscovery: TVDiscovering, @unchecked Sendable {
    public struct Options: Sendable {
        public var useBonjour: Bool
        public var useSubnetSweep: Bool
        public var useSSDP: Bool
        /// Head start for the cheap paths before the sweep begins.
        public var sweepDelay: TimeInterval
        public var sweepConnectTimeout: TimeInterval
        public var sweepConcurrency: Int
        public var maxSweepHosts: Int

        public init(useBonjour: Bool = true, useSubnetSweep: Bool = true, useSSDP: Bool = true, sweepDelay: TimeInterval = 0.3,
                    sweepConnectTimeout: TimeInterval = 0.4, sweepConcurrency: Int = 64, maxSweepHosts: Int = 1024) {
            self.useBonjour = useBonjour; self.useSubnetSweep = useSubnetSweep; self.useSSDP = useSSDP
            self.sweepDelay = sweepDelay; self.sweepConnectTimeout = sweepConnectTimeout
            self.sweepConcurrency = sweepConcurrency; self.maxSweepHosts = maxSweepHosts
        }
    }

    public let options: Options

    public init(options: Options = Options()) { self.options = options }

    public func discover(timeout: TimeInterval) -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let run = DiscoveryRun(options: options, continuation: continuation)
            continuation.onTermination = { _ in run.finish() }
            run.start(timeout: timeout)
        }
    }

    /// Accepts "192.168.1.20", "LGwebOSTV.local", "192.168.1.20:3000", "ws://192.168.1.20:3000/". Lenient: since the
    /// user typed the address, an open SSAP port is enough when the TV doesn't answer SSDP.
    public func probe(host: String) async -> TVDevice? {
        guard let cleaned = Self.cleanHostInput(host) else { return nil }
        return await NetIO.background {
            guard let ip = NetIO.resolveIPv4(cleaned) else { return nil }
            let identity = TVIdentifier.identify(ip: ip, hints: DiscoveryHints(), lenient: true)
            return identity.confirmed ? TVIdentifier.makeDevice(ip: ip, hints: DiscoveryHints(), identity: identity) : nil
        }
    }

    /// Fast TCP check of the TV's SSAP ports (3000/3001).
    public func isReachable(host: String) async -> Bool { await TVReachability.isReachable(host: host) }

    static func cleanHostInput(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty || s.contains(" ") ? nil : s
    }
}

// MARK: - Reachability

public enum TVReachability {
    /// True if TCP 3000 or 3001 accepts a connection within `timeout` (both are tried in parallel).
    public static func isReachable(host: String, timeout: TimeInterval = 0.8) async -> Bool {
        await NetIO.background {
            guard let ip = NetIO.resolveIPv4(host) else { return false }
            var open = false
            SubnetSweep.scan([(ip, 3000), (ip, 3001)], timeout: timeout, window: 2, isCancelled: { open }) { _, outcome in
                if outcome == .open { open = true }
            }
            return open
        }
    }
}

// MARK: - Identification

struct TVIdentity: Sendable, Equatable {
    var ssdp: SSDP.Response?
    var description: UPnPDescription?
    var confirmed: Bool
}

enum TVIdentifier {
    /// Confirms a host is a webOS TV and learns its UUID / name / model. Blocking (≤ ~3.5 s, ~50 ms for a TV).
    /// Accepted when: it answers unicast SSDP for the webOS second-screen service; or port 3000 says "Hello world"
    /// and 3001 is open; or (Bonjour said LG, or `lenient`) and either SSAP port answers.
    static func identify(ip: UInt32, hints: DiscoveryHints, lenient: Bool) -> TVIdentity {
        var ssdp: SSDP.Response?
        if let uuid = hints.upnpUUID {
            ssdp = SSDP.Response(ip: ip, uuid: uuid, location: hints.location, searchTarget: SSDP.webOSSearchTarget)
        } else {
            ssdp = SSDP.unicastProbe(ip)
        }
        var confirmed = ssdp != nil
        if !confirmed {
            let hello = NetIO.httpGet(ip, port: 3000, path: "/", timeout: 1.0).map { $0.bodyText.contains("Hello world") } ?? false
            let secure = NetIO.isPortOpen(ip, port: 3001, timeout: 0.8)
            confirmed = (hello && secure) || ((hints.isLGBonjour || lenient) && (hello || secure))
        }
        let description = confirmed ? ssdp?.location.flatMap { UPnPDescription.fetch(location: $0, expectedIP: ip) } : nil
        return TVIdentity(ssdp: ssdp, description: description, confirmed: confirmed)
    }

    static func makeDevice(ip: UInt32, hints: DiscoveryHints, identity: TVIdentity) -> TVDevice {
        let host = NetIO.ipv4String(ip)
        let id: String
        if let uuid = identity.ssdp?.uuid ?? hints.upnpUUID {
            id = "uuid:\(uuid)"
        } else if let airplay = hints.airPlayDeviceID {
            id = "airplay:\(airplay)"
        } else {
            id = "host:\(host)"
        }
        let name = displayName(identity.description?.friendlyName) ?? displayName(hints.airPlayName)
            ?? displayName(hints.homeKitName) ?? TVDeviceMerge.fallbackName(host: host)
        let model = identity.description?.modelNumber.flatMap { $0.isEmpty ? nil : $0 } ?? hints.model
        return TVDevice(id: id, name: name, host: host, macAddresses: hints.macAddresses, modelName: model)
    }

    /// "[LG] webOS TV SM8000PLA" → "LG webOS TV SM8000PLA"; "[LG] Living Room" → "Living Room".
    static func displayName(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("[LG]") { s = s.dropFirst(4).trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("webos") { s = "LG " + s }
        return s
    }
}

// MARK: - One discovery run

final class DiscoveryRun: @unchecked Sendable {
    private enum HostState { case verifying, emitted, rejected }
    private struct HostEntry { var hints: DiscoveryHints; var state: HostState }

    private let options: TVDiscovery.Options
    private let continuation: AsyncStream<TVDevice>.Continuation
    private let lock = NSLock()
    private var stopped = false
    private var hosts: [UInt32: HostEntry] = [:]
    private var emittedIDs: Set<String> = []
    private var bonjour: BonjourBrowser?

    init(options: TVDiscovery.Options, continuation: AsyncStream<TVDevice>.Continuation) {
        self.options = options
        self.continuation = continuation
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func start(timeout: TimeInterval) {
        let lan = NetworkInterfaces.primaryLAN()
        if options.useBonjour {
            let browser = BonjourBrowser()
            lock.withLock { bonjour = browser }
            browser.start { [weak self] ip, hints in self?.offer(ip, hints) }
        }
        if options.useSSDP {
            DispatchQueue.global(qos: .utility).async { [self] in
                SSDP.search(destination: SSDP.multicastGroup, timeout: timeout, sendTimes: [0, 0.4, 1.5], interface: lan,
                            isCancelled: { self.isStopped }) { response in
                    var hints = DiscoveryHints()
                    hints.upnpUUID = response.uuid
                    hints.location = response.location
                    self.offer(response.ip, hints)
                    return false
                }
            }
        }
        if options.useSubnetSweep, let lan {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + options.sweepDelay) { [self] in
                guard !isStopped else { return }
                let candidates = SubnetSweep.hosts(for: lan, cap: options.maxSweepHosts)
                SubnetSweep.findWebOSCandidates(hosts: candidates, timeout: options.sweepConnectTimeout,
                                                window: options.sweepConcurrency, isCancelled: { self.isStopped }) { ip, _ in
                    self.offer(ip, DiscoveryHints())
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { [self] in finish() }
    }

    func finish() {
        let browser: BonjourBrowser? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { bonjour = nil }
            return bonjour
        }
        browser?.stop()
        continuation.finish()
    }

    /// A source found `ip`. Verifies each host once; merges later hints (used when the device is built).
    func offer(_ ip: UInt32, _ hints: DiscoveryHints) {
        let snapshot: DiscoveryHints? = lock.withLock {
            guard !stopped else { return nil }
            guard var entry = hosts[ip] else {
                hosts[ip] = HostEntry(hints: hints, state: .verifying)
                return hints
            }
            let wasLG = entry.hints.isLGBonjour
            entry.hints.merge(hints)
            // A sweep hit that failed verification gets one more chance once Bonjour vouches for it as an LG TV.
            let retry = entry.state == .rejected && hints.isLGBonjour && !wasLG
            if retry { entry.state = .verifying }
            hosts[ip] = entry
            return retry ? entry.hints : nil
        }
        guard let snapshot else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let identity = TVIdentifier.identify(ip: ip, hints: snapshot, lenient: false)
            complete(ip, identity)
        }
    }

    private func complete(_ ip: UInt32, _ identity: TVIdentity) {
        let device: TVDevice? = lock.withLock {
            guard !stopped, var entry = hosts[ip] else { return nil }
            entry.state = identity.confirmed ? .emitted : .rejected
            hosts[ip] = entry
            guard identity.confirmed else { return nil }
            let device = TVIdentifier.makeDevice(ip: ip, hints: entry.hints, identity: identity)
            return emittedIDs.insert(device.id).inserted ? device : nil
        }
        if let device { continuation.yield(device) }
    }
}
