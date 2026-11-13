import XCTest
@testable import LGKit

/// Live checks against a real TV on the LAN. Skipped unless `LGKIT_LIVE_TV=<tv ip>` is set, e.g.
///   LGKIT_LIVE_TV=192.168.178.250 swift test --filter DiscoveryLiveTests
/// Read-only apart from one harmless Wake-on-LAN packet burst (the TV is already on).
final class DiscoveryLiveTests: XCTestCase {
    private var tvIP: String!

    override func setUpWithError() throws {
        guard let ip = ProcessInfo.processInfo.environment["LGKIT_LIVE_TV"], !ip.isEmpty else {
            throw XCTSkip("set LGKIT_LIVE_TV=<ip> to run live discovery tests")
        }
        tvIP = ip
    }

    /// Runs discovery with only the given source and returns the TV (if found) plus time to first sighting.
    private func run(_ options: TVDiscovery.Options, label: String, timeout: TimeInterval = 8) async -> TVDevice? {
        let start = Date()
        var found: TVDevice?
        for await device in TVDiscovery(options: options).discover(timeout: timeout) {
            let t = Date().timeIntervalSince(start)
            print("[live] \(label): \(String(format: "%.3f", t)) s → \(device.name) id=\(device.id) host=\(device.host) model=\(device.modelName ?? "-") macs=\(device.macAddresses)")
            if device.host == tvIP { found = device; break }
        }
        return found
    }

    func testBonjourFindsTV() async {
        let tv = await run(.init(useBonjour: true, useSubnetSweep: false, useSSDP: false), label: "bonjour")
        XCTAssertNotNil(tv)
        XCTAssertTrue(tv?.id.hasPrefix("uuid:") ?? false)
    }

    func testSubnetSweepFindsTV() async {
        let tv = await run(.init(useBonjour: false, useSubnetSweep: true, useSSDP: false, sweepDelay: 0), label: "sweep")
        XCTAssertNotNil(tv)
        XCTAssertTrue(tv?.id.hasPrefix("uuid:") ?? false)
    }

    func testSSDPFindsTV() async {
        let tv = await run(.init(useBonjour: false, useSubnetSweep: false, useSSDP: true), label: "ssdp")
        XCTAssertNotNil(tv)
        XCTAssertTrue(tv?.id.hasPrefix("uuid:") ?? false)
    }

    func testAllSourcesAgreeOnOneDevice() async {
        let start = Date()
        var devices: [TVDevice] = []
        for await d in TVDiscovery().discover(timeout: 4) { devices.append(d) }
        print("[live] all sources, 4 s run: \(devices.map { "\($0.id)@\($0.host)" }) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        XCTAssertEqual(devices.filter { $0.host == tvIP }.count, 1)
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
    }

    func testFullSweepDuration() throws {
        guard let lan = NetworkInterfaces.primaryLAN() else { throw XCTSkip("no LAN interface") }
        let hosts = SubnetSweep.hosts(for: lan)
        let start = Date()
        var hits: [String] = []
        SubnetSweep.findWebOSCandidates(hosts: hosts, isCancelled: { false }) { ip, port in hits.append("\(NetIO.ipv4String(ip)):\(port)") }
        let elapsed = Date().timeIntervalSince(start)
        print("[live] sweep of \(hosts.count) hosts on \(lan.name): \(String(format: "%.2f", elapsed)) s, candidates \(hits)")
        XCTAssertTrue(hits.contains("\(tvIP!):3000"))
        XCTAssertLessThan(elapsed, 6)
    }

    func testProbeAndReachability() async {
        let start = Date()
        let tv = await TVDiscovery().probe(host: tvIP)
        print("[live] probe: \(String(format: "%.3f", Date().timeIntervalSince(start))) s → \(String(describing: tv))")
        XCTAssertEqual(tv?.host, tvIP)
        let reachable = await TVDiscovery().isReachable(host: tvIP)
        XCTAssertTrue(reachable)
    }

    func testWakeOnLANSends() async {
        // Harmless: the TV is already on. Uses the TV's real Wi‑Fi MAC (from ARP) when known.
        let sent = await WakeOnLAN.wake(macAddresses: ["44:cb:8b:3d:9e:70"], lastKnownHost: tvIP)
        XCTAssertTrue(sent)
        let tv = TVDevice(id: "x", name: "TV", host: tvIP, macAddresses: ["44:cb:8b:3d:9e:70"])
        let awake = await WakeOnLAN.wakeAndWait(device: tv, timeout: 3)
        XCTAssertTrue(awake)
    }
}
