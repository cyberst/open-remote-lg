import XCTest
import Darwin
@testable import LGKit

final class DiscoveryTests: XCTestCase {
    // MARK: Subnet math

    func testSweepHostsFor24ExcludesSelfNetworkAndBroadcast() {
        let iface = IPv4Interface(name: "en0", address: 0xC0A8_B248, netmask: 0xFFFF_FF00) // 192.168.178.72/24
        let hosts = SubnetSweep.hosts(for: iface)
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains(0xC0A8_B248))
        XCTAssertFalse(hosts.contains(0xC0A8_B200))
        XCTAssertFalse(hosts.contains(0xC0A8_B2FF))
        XCTAssertEqual(hosts.first, 0xC0A8_B201)
        XCTAssertEqual(NetIO.ipv4String(iface.broadcast), "192.168.178.255")
    }

    func testSweepHostsLargeSubnetIsCappedAroundOwnAddress() {
        let iface = IPv4Interface(name: "en0", address: 0x0A00_1234, netmask: 0xFF00_0000) // 10.0.18.52/8
        let hosts = SubnetSweep.hosts(for: iface, cap: 1024)
        XCTAssertLessThanOrEqual(hosts.count, 1024)
        XCTAssertEqual(hosts.count, 1021)
        XCTAssertTrue(hosts.allSatisfy { $0 & 0xFFFF_FC00 == 0x0A00_1000 })
    }

    func testSweepHostsTinySubnets() {
        XCTAssertTrue(SubnetSweep.hosts(for: IPv4Interface(name: "en0", address: 0x0A00_0001, netmask: 0xFFFF_FFFF)).isEmpty)
        XCTAssertEqual(SubnetSweep.hosts(for: IPv4Interface(name: "en0", address: 0x0A00_0001, netmask: 0xFFFF_FFFC)), [0x0A00_0002])
    }

    func testPrimaryLANPrefersEn0AndSkipsNonLAN() {
        let list = [IPv4Interface(name: "utun3", address: 0x0A08_0001, netmask: 0xFFFF_FF00),
                    IPv4Interface(name: "pdp_ip0", address: 0x0A40_0001, netmask: 0xFFFF_FFFF),
                    IPv4Interface(name: "en1", address: 0xA9FE_0101, netmask: 0xFFFF_0000),
                    IPv4Interface(name: "en2", address: 0xC0A8_0002, netmask: 0xFFFF_FF00),
                    IPv4Interface(name: "en0", address: 0xC0A8_0103, netmask: 0xFFFF_FF00)]
        XCTAssertEqual(NetworkInterfaces.primaryLAN(from: list)?.name, "en0")
        XCTAssertEqual(NetworkInterfaces.primaryLAN(from: Array(list.dropLast()))?.name, "en2")
        XCTAssertNil(NetworkInterfaces.primaryLAN(from: Array(list.prefix(3))))
    }

    // MARK: Port scanning against a local listener

    func testScanReportsOpenAndRefusedPorts() throws {
        let (listener, openPort) = try makeListener()
        defer { close(listener) }
        let closedPort = try unusedPort()
        var outcomes: [Int: NetIO.ConnectOutcome] = [:]
        SubnetSweep.scan([(0x7F00_0001, openPort), (0x7F00_0001, closedPort)], timeout: 0.5, window: 2,
                         isCancelled: { false }) { outcomes[$0] = $1 }
        XCTAssertEqual(outcomes[0], .open)
        XCTAssertEqual(outcomes[1], .refused)
        XCTAssertTrue(NetIO.isPortOpen(0x7F00_0001, port: openPort, timeout: 0.5))
        XCTAssertFalse(NetIO.isPortOpen(0x7F00_0001, port: closedPort, timeout: 0.5))
    }

    // MARK: SSDP / UPnP parsing

    let ssdpResponse = """
    HTTP/1.1 200 OK\r
    Location: http://192.168.178.250:1309/\r
    Cache-Control: max-age=1800\r
    Server: WebOS/4.1.0 UPnP/1.0\r
    EXT: \r
    USN: uuid:9AF5B682-6076-7999-9cde-240534a2e96d::urn:lge-com:service:webos-second-screen:1\r
    ST: urn:lge-com:service:webos-second-screen:1\r
    \r

    """

    func testParseSSDPResponse() throws {
        let r = try XCTUnwrap(SSDP.parse(Data(ssdpResponse.utf8), from: 0xC0A8_B2FA))
        XCTAssertEqual(r.uuid, "9af5b682-6076-7999-9cde-240534a2e96d")
        XCTAssertEqual(r.location, "http://192.168.178.250:1309/")
        XCTAssertTrue(r.isWebOSSecondScreen)
        XCTAssertNil(SSDP.parse(Data("M-SEARCH * HTTP/1.1\r\n\r\n".utf8), from: 1))
        XCTAssertEqual(SSDP.uuid(fromUSN: "uuid:abc"), "abc")
        XCTAssertNil(SSDP.uuid(fromUSN: "urn:foo"))
    }

    func testSearchMessageFormat() {
        let m = SSDP.searchMessage(host: "239.255.255.250")
        XCTAssertTrue(m.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"))
        XCTAssertTrue(m.contains("ST: urn:lge-com:service:webos-second-screen:1\r\n"))
        XCTAssertTrue(m.hasSuffix("\r\n\r\n"))
    }

    func testParseUPnPDescription() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
          <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
          <friendlyName>[LG] webOS TV SM8000PLA</friendlyName>
          <manufacturer>LG Electronics</manufacturer>
          <modelName>LG Smart TV</modelName>
          <modelNumber>55SM8000PLA</modelNumber>
          <UDN>uuid:9af5b682-6076-7999-9cde-240534a2e96d</UDN>
          <deviceList><device><friendlyName>Embedded</friendlyName></device></deviceList>
        </device></root>
        """
        let d = try XCTUnwrap(UPnPDescription.parse(Data(xml.utf8)))
        XCTAssertEqual(d.friendlyName, "[LG] webOS TV SM8000PLA")
        XCTAssertEqual(d.modelNumber, "55SM8000PLA")
        XCTAssertEqual(d.manufacturer, "LG Electronics")
        XCTAssertNil(UPnPDescription.parse(Data("not xml".utf8)))
    }

    func testDescriptionFetchRefusesForeignLocation() {
        XCTAssertNil(UPnPDescription.fetch(location: "http://8.8.8.8:80/", expectedIP: 0xC0A8_B2FA, timeout: 0.1))
        XCTAssertNil(UPnPDescription.fetch(location: "https://192.168.178.250/", expectedIP: 0xC0A8_B2FA, timeout: 0.1))
    }

    // MARK: HTTP

    func testHTTPResponseParsingAndDechunking() throws {
        let plain = try XCTUnwrap(HTTPResponse(raw: Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nHello world\r\n".utf8)))
        XCTAssertEqual(plain.status, 200)
        XCTAssertTrue(plain.bodyText.contains("Hello world"))
        let chunked = try XCTUnwrap(HTTPResponse(raw: Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n6\r\n world\r\n0\r\n\r\n".utf8)))
        XCTAssertEqual(chunked.bodyText, "Hello world")
        XCTAssertNil(HTTPResponse(raw: Data("garbage".utf8)))
    }

    // MARK: Bonjour TXT → hints

    func testAirPlayLGHints() throws {
        let txt = ["deviceid": "56:CD:61:61:D5:91", "manufacturer": "LG Electronics", "model": "55SM8000PLA",
                   "serialNumber": "003IKQT0K308_20:17:42:d6:55:d7\n"]
        let h = try XCTUnwrap(BonjourTV.hints(serviceType: "_airplay._tcp", name: "[LG] webOS TV SM8000PLA", txt: txt))
        XCTAssertTrue(h.isLGBonjour)
        XCTAssertEqual(h.model, "55SM8000PLA")
        XCTAssertEqual(h.airPlayDeviceID, "56:cd:61:61:d5:91")
        XCTAssertEqual(h.macAddresses, ["20:17:42:d6:55:d7"])
    }

    func testNonLGAirPlayIgnored() {
        XCTAssertNil(BonjourTV.hints(serviceType: "_airplay._tcp", name: "Ali’s MacBook Pro", txt: ["manufacturer": "Apple Inc.", "model": "Mac15,3"]))
        XCTAssertNil(BonjourTV.hints(serviceType: "_hap._tcp", name: "Hue Bridge", txt: ["md": "BSB002"]))
        XCTAssertNil(BonjourTV.hints(serviceType: "_printer._tcp", name: "[LG] x", txt: [:]))
    }

    func testHomeKitLGHints() throws {
        let h = try XCTUnwrap(BonjourTV.hints(serviceType: "_hap._tcp.", name: "LG webOS TV 6D11", txt: ["md": "WEBOS", "id": "56:CD:61:61:D5:91"]))
        XCTAssertEqual(h.homeKitName, "LG webOS TV 6D11")
        XCTAssertNil(h.airPlayDeviceID)
    }

    // MARK: Device building

    func testMakeDevicePrefersUUIDAndFriendlyName() {
        var hints = DiscoveryHints()
        hints.airPlayName = "[LG] webOS TV SM8000PLA"
        hints.airPlayDeviceID = "56:cd:61:61:d5:91"
        hints.macAddresses = ["20:17:42:d6:55:d7"]
        hints.model = "55SM8000PLA"
        let identity = TVIdentity(ssdp: SSDP.Response(ip: 0xC0A8_B2FA, uuid: "9af5", location: nil),
                                  description: UPnPDescription(friendlyName: "[LG] Living Room", modelNumber: "55SM8000PLA"),
                                  confirmed: true)
        let d = TVIdentifier.makeDevice(ip: 0xC0A8_B2FA, hints: hints, identity: identity)
        XCTAssertEqual(d.id, "uuid:9af5")
        XCTAssertEqual(d.name, "Living Room")
        XCTAssertEqual(d.host, "192.168.178.250")
        XCTAssertEqual(d.modelName, "55SM8000PLA")
        XCTAssertEqual(d.macAddresses, ["20:17:42:d6:55:d7"])
    }

    func testMakeDeviceFallbacks() {
        var hints = DiscoveryHints()
        hints.airPlayDeviceID = "56:cd:61:61:d5:91"
        let none = TVIdentity(ssdp: nil, description: nil, confirmed: true)
        XCTAssertEqual(TVIdentifier.makeDevice(ip: 0x0A00_0005, hints: hints, identity: none).id, "airplay:56:cd:61:61:d5:91")
        let bare = TVIdentifier.makeDevice(ip: 0x0A00_0005, hints: DiscoveryHints(), identity: none)
        XCTAssertEqual(bare.id, "host:10.0.0.5")
        XCTAssertEqual(bare.name, "LG TV (10.0.0.5)")
    }

    func testDisplayNameCleanup() {
        XCTAssertEqual(TVIdentifier.displayName("[LG] webOS TV SM8000PLA"), "LG webOS TV SM8000PLA")
        XCTAssertEqual(TVIdentifier.displayName("  [LG] Bedroom "), "Bedroom")
        XCTAssertEqual(TVIdentifier.displayName("LG webOS TV 6D11"), "LG webOS TV 6D11")
        XCTAssertNil(TVIdentifier.displayName("[LG]"))
        XCTAssertNil(TVIdentifier.displayName(nil))
    }

    func testCleanHostInput() {
        XCTAssertEqual(TVDiscovery.cleanHostInput(" 192.168.1.20 "), "192.168.1.20")
        XCTAssertEqual(TVDiscovery.cleanHostInput("ws://192.168.1.20:3000/"), "192.168.1.20")
        XCTAssertEqual(TVDiscovery.cleanHostInput("LGwebOSTV.local."), "LGwebOSTV.local")
        XCTAssertNil(TVDiscovery.cleanHostInput("   "))
        XCTAssertNil(TVDiscovery.cleanHostInput("not a host"))
    }

    func testHintsMerge() {
        var a = DiscoveryHints(); a.macAddresses = ["aa:bb:cc:dd:ee:ff"]
        var b = DiscoveryHints(); b.upnpUUID = "u"; b.macAddresses = ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"]; b.isLGBonjour = true
        a.merge(b)
        XCTAssertEqual(a.upnpUUID, "u")
        XCTAssertEqual(a.macAddresses.count, 2)
        XCTAssertTrue(a.isLGBonjour)
    }

    func testDiscoveryWithAllSourcesDisabledFinishesOnTimeout() async {
        let discovery = TVDiscovery(options: .init(useBonjour: false, useSubnetSweep: false, useSSDP: false))
        let start = Date()
        var count = 0
        for await _ in discovery.discover(timeout: 0.2) { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testProbeRejectsEmptyInput() async {
        let device = await TVDiscovery(options: .init(useBonjour: false, useSubnetSweep: false, useSSDP: false)).probe(host: "  ")
        XCTAssertNil(device)
    }

    // MARK: Helpers

    private func makeListener() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = NetIO.sockaddrIn(0x7F00_0001, port: 0)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw XCTSkip("cannot listen on loopback") }
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: out.sin_port))
    }

    private func unusedPort() throws -> UInt16 {
        let (fd, port) = try makeListener()
        close(fd)
        return port
    }
}

final class DiscoveryMergeTests: XCTestCase {
    let saved = TVDevice(id: "uuid:9af5", name: "Living Room", host: "192.168.1.10", macAddresses: ["44:CB:8B:3D:9E:70"],
                         modelName: nil, useSecureSocket: true, lastConnected: Date(timeIntervalSince1970: 1000))

    func testMatchByIDUpdatesHostAndKeepsIdentity() {
        let found = TVDevice(id: "uuid:9af5", name: "LG webOS TV SM8000PLA", host: "192.168.1.42", macAddresses: ["20:17:42:d6:55:d7"], modelName: "55SM8000PLA")
        let merged = TVDeviceMerge.merge([found], into: [saved])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "uuid:9af5")
        XCTAssertEqual(merged[0].host, "192.168.1.42")
        XCTAssertEqual(merged[0].name, "Living Room")
        XCTAssertEqual(merged[0].modelName, "55SM8000PLA")
        XCTAssertEqual(merged[0].macAddresses, ["44:CB:8B:3D:9E:70", "20:17:42:d6:55:d7"])
        XCTAssertEqual(merged[0].useSecureSocket, true)
        XCTAssertEqual(merged[0].lastConnected, Date(timeIntervalSince1970: 1000))
    }

    func testMatchByMACAcrossFormats() {
        let found = TVDevice(id: "airplay:56:cd:61:61:d5:91", name: "x", host: "192.168.1.50", macAddresses: ["44-cb-8b-3d-9e-70"])
        XCTAssertTrue(TVDeviceMerge.isSameTV(saved, found))
        XCTAssertEqual(TVDeviceMerge.merge([found], into: [saved])[0].host, "192.168.1.50")
    }

    func testHostBasedIDsMatchOnHostOnly() {
        let hostOnly = TVDevice(id: "host:192.168.1.10", name: "LG TV (192.168.1.10)", host: "192.168.1.10")
        let found = TVDevice(id: "uuid:other", name: "LG webOS TV", host: "192.168.1.10")
        XCTAssertTrue(TVDeviceMerge.isSameTV(hostOnly, found))
        let merged = TVDeviceMerge.merge([found], into: [hostOnly])
        XCTAssertEqual(merged[0].id, "host:192.168.1.10", "saved id is kept so its pairing key stays valid")
        XCTAssertEqual(merged[0].name, "LG webOS TV", "placeholder names are upgraded")
        // Two strong ids on the same IP are different TVs.
        XCTAssertFalse(TVDeviceMerge.isSameTV(saved, TVDevice(id: "uuid:zzz", name: "", host: "192.168.1.10")))
    }

    func testUnmatchedAppendOnlyWhenAsked() {
        let other = TVDevice(id: "uuid:new", name: "Bedroom", host: "192.168.1.77")
        XCTAssertEqual(TVDeviceMerge.merge([other], into: [saved]).count, 1)
        XCTAssertEqual(TVDeviceMerge.merge([other], into: [saved], appendNew: true).map(\.id), ["uuid:9af5", "uuid:new"])
    }

    func testDemoAndZeroMACsNeverMatch() {
        let zeroA = TVDevice(id: "a", name: "", host: "1", macAddresses: ["00:00:00:00:00:00"])
        let zeroB = TVDevice(id: "b", name: "", host: "2", macAddresses: ["00:00:00:00:00:00"])
        XCTAssertFalse(TVDeviceMerge.isSameTV(zeroA, zeroB))
        XCTAssertFalse(TVDeviceMerge.isSameTV(.demo, TVDevice(id: "host:demo.local", name: "", host: "demo.local")))
        XCTAssertEqual(TVDeviceMerge.merge([.demo], into: [saved], appendNew: true).count, 1)
    }
}
