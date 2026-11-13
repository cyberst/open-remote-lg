import XCTest
@testable import LGKit

final class WakeTests: XCTestCase {
    func testMACParsingFormats() {
        let expected: [UInt8] = [0x44, 0xCB, 0x8B, 0x3D, 0x9E, 0x70]
        for s in ["44:cb:8b:3d:9e:70", "44-CB-8B-3D-9E-70", "44cb8b3d9e70", "44cb.8b3d.9e70", " 44:CB:8B:3D:9E:70\n"] {
            XCTAssertEqual(MACAddress.bytes(s), expected, s)
        }
        XCTAssertEqual(MACAddress.bytes("0:1b:2:3d:4e:5f"), [0x00, 0x1B, 0x02, 0x3D, 0x4E, 0x5F])
        for bad in ["", "44:cb:8b:3d:9e", "44:cb:8b:3d:9e:70:11", "zz:cb:8b:3d:9e:70", "44cb8b3d9e7", "123:4:5:6:7:8"] {
            XCTAssertNil(MACAddress.bytes(bad), bad)
        }
        XCTAssertEqual(MACAddress.normalized("44-CB-8B-3D-9E-70"), "44:cb:8b:3d:9e:70")
    }

    func testUsableMACs() {
        XCTAssertTrue(MACAddress.isUsable("44:cb:8b:3d:9e:70"))
        XCTAssertFalse(MACAddress.isUsable("00:00:00:00:00:00"))
        XCTAssertFalse(MACAddress.isUsable("ff:ff:ff:ff:ff:ff"))
        XCTAssertFalse(MACAddress.isUsable("01:00:5e:00:00:01"))
    }

    func testFirstMACInText() {
        XCTAssertEqual(MACAddress.firstMAC(in: "003IKQT0K308_20:17:42:d6:55:d7\n"), "20:17:42:d6:55:d7")
        XCTAssertNil(MACAddress.firstMAC(in: "003IKQT0K308"))
        XCTAssertNil(MACAddress.firstMAC(in: "20:17-42:d6:55:d7"))
    }

    func testMagicPacket() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(for: "44-cb-8b-3d-9e-70"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet[0..<6]), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0x44, 0xCB, 0x8B, 0x3D, 0x9E, 0x70]
        for i in 0..<16 { XCTAssertEqual(Array(packet[(6 + i * 6)..<(12 + i * 6)]), mac) }
        XCTAssertNil(WakeOnLAN.magicPacket(for: "nope"))
    }

    func testWakeWithoutUsableMACsSendsNothing() async {
        let sentA = await WakeOnLAN.wake(macAddresses: [], lastKnownHost: nil)
        let sentB = await WakeOnLAN.wake(macAddresses: ["garbage", "00:00:00:00:00:00"], lastKnownHost: nil)
        XCTAssertFalse(sentA)
        XCTAssertFalse(sentB)
    }

    func testDestinationsIncludeBroadcastAndHost() {
        let d = WakeOnLAN.destinations(lastKnownHost: "192.168.178.250")
        XCTAssertEqual(d.ips.first, 0xFFFF_FFFF)
        XCTAssertTrue(d.ips.contains(0xC0A8_B2FA))
        XCTAssertEqual(Set(d.ips).count, d.ips.count)
    }

    func testWakeAndWaitReturnsWhenReachable() async {
        let counter = Counter()
        let tv = TVDevice(id: "x", name: "TV", host: "10.0.0.9", macAddresses: ["44:cb:8b:3d:9e:70"])
        let ok = await WakeOnLAN.wakeAndWait(device: tv, timeout: 5, isReachable: { _ in counter.tick() >= 3 },
                                             sendWake: { _, _ in counter.wake(); return true }, resendInterval: 3, pollInterval: 0.05)
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(counter.wakes, 1)
    }

    func testWakeAndWaitTimesOut() async {
        let counter = Counter()
        let tv = TVDevice(id: "x", name: "TV", host: "10.0.0.9", macAddresses: ["44:cb:8b:3d:9e:70"])
        let start = Date()
        let ok = await WakeOnLAN.wakeAndWait(device: tv, timeout: 0.5, isReachable: { _ in false },
                                             sendWake: { _, _ in counter.wake(); return true }, resendInterval: 0.2, pollInterval: 0.05)
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertGreaterThanOrEqual(counter.wakes, 2)
    }

    func testWakeAndWaitSkipsWakeWhenAlreadyOn() async {
        let counter = Counter()
        let tv = TVDevice(id: "x", name: "TV", host: "10.0.0.9", macAddresses: ["44:cb:8b:3d:9e:70"])
        let ok = await WakeOnLAN.wakeAndWait(device: tv, timeout: 5, isReachable: { _ in true },
                                             sendWake: { _, _ in counter.wake(); return true })
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.wakes, 0)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks = 0
        private var wakeCount = 0
        func tick() -> Int { lock.withLock { ticks += 1; return ticks } }
        func wake() { lock.withLock { wakeCount += 1 } }
        var wakes: Int { lock.withLock { wakeCount } }
    }
}
