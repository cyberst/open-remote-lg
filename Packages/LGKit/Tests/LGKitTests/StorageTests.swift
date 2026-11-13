import XCTest
import Security
@testable import LGKit

final class StorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LGKitStorageTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var fileURL: URL { dir.appendingPathComponent("nested/devices.json") }

    private let tv = TVDevice(id: "uuid:9af5", name: "Living Room", host: "192.168.178.250", macAddresses: ["44:cb:8b:3d:9e:70"],
                              modelName: "55SM8000PLA", webOSVersion: "4.5", useSecureSocket: true,
                              lastConnected: Date(timeIntervalSinceReferenceDate: 812_345_678.123))

    func testEmptyWhenNoFile() {
        let store = FileDeviceStore(fileURL: fileURL)
        XCTAssertEqual(store.loadDevices(), [])
        XCTAssertNil(store.lastUsedDeviceID())
    }

    func testRoundTripAcrossInstances() throws {
        let store = FileDeviceStore(fileURL: fileURL)
        store.saveDevices([tv, .demo])
        store.setLastUsedDeviceID(tv.id)
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = FileDeviceStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.loadDevices(), [tv, .demo])
        XCTAssertEqual(reloaded.lastUsedDeviceID(), tv.id)

        reloaded.setLastUsedDeviceID(nil)
        reloaded.flush()
        XCTAssertNil(FileDeviceStore(fileURL: fileURL).lastUsedDeviceID())
    }

    func testFileIsVersioned() throws {
        let store = FileDeviceStore(fileURL: fileURL)
        store.saveDevices([tv])
        store.flush()
        let json = try JSON.parse(Data(contentsOf: fileURL))
        XCTAssertEqual(json["version"]?.intValue, FileDeviceStore.formatVersion)
        XCTAssertEqual(json["devices"]?.arrayValue?.count, 1)
    }

    func testCorruptFileIsSetAsideAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: fileURL)
        let store = FileDeviceStore(fileURL: fileURL)
        XCTAssertEqual(store.loadDevices(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
        store.saveDevices([tv])
        store.flush()
        XCTAssertEqual(FileDeviceStore(fileURL: fileURL).loadDevices(), [tv])
    }

    func testBadEntriesAreSkippedAndUnknownFieldsIgnored() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"version": 7, "futureField": [1, 2],
         "lastUsedDeviceID": "good",
         "devices": [
            {"id": "broken"},
            {"id": "good", "name": "TV", "host": "10.0.0.2", "macAddresses": [], "isDemo": false, "newerField": {"x": 1}},
            42
         ]}
        """
        try Data(json.utf8).write(to: fileURL)
        let store = FileDeviceStore(fileURL: fileURL)
        XCTAssertEqual(store.loadDevices().map(\.id), ["good"])
        XCTAssertEqual(store.lastUsedDeviceID(), "good")
    }

    func testConcurrentWritesEndConsistent() {
        let store = FileDeviceStore(fileURL: fileURL)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            store.saveDevices([TVDevice(id: "d\(i)", name: "TV \(i)", host: "10.0.0.\(i)")])
        }
        store.flush()
        XCTAssertEqual(FileDeviceStore(fileURL: fileURL).loadDevices(), store.loadDevices())
    }

    // MARK: Keychain store

    final class MemoryBackend: SecretBackend, @unchecked Sendable {
        let lock = NSLock()
        var items: [String: String] = [:]
        var failWrites = false
        func read(service: String, account: String) -> String? { lock.withLock { items["\(service)|\(account)"] } }
        func write(_ value: String, service: String, account: String) -> Bool {
            lock.withLock { if failWrites { return false }; items["\(service)|\(account)"] = value; return true }
        }
        func delete(service: String, account: String) { lock.withLock { items["\(service)|\(account)"] = nil } }
    }

    func testKeyStoreUsesServiceAndAccount() {
        let backend = MemoryBackend()
        let store = KeychainKeyStore(backend: backend)
        XCTAssertNil(store.clientKey(for: "uuid:a"))
        store.setClientKey("secret", for: "uuid:a")
        XCTAssertEqual(backend.items["com.simber.openremoteforlg.clientkey|uuid:a"], "secret")
        XCTAssertEqual(KeychainKeyStore(backend: backend).clientKey(for: "uuid:a"), "secret")
        store.setClientKey(nil, for: "uuid:a")
        XCTAssertNil(store.clientKey(for: "uuid:a"))
        XCTAssertTrue(backend.items.isEmpty)
    }

    func testKeyStoreKeepsKeyInMemoryWhenKeychainFails() {
        let backend = MemoryBackend()
        backend.failWrites = true
        let store = KeychainKeyStore(backend: backend)
        store.setClientKey("k", for: "x")
        XCTAssertEqual(store.clientKey(for: "x"), "k")
    }

    /// The real Keychain needs a signed host with a keychain entitlement; plain `swift test` usually lacks it.
    func testSystemKeychainRoundTripWhenAvailable() throws {
        let keychain = SystemKeychain()
        let service = "com.simber.openremoteforlg.tests.\(UUID().uuidString)"
        guard keychain.write("value-1", service: service, account: "acct") else {
            throw XCTSkip("Keychain not available to this test process (missing entitlement)")
        }
        defer { keychain.delete(service: service, account: "acct") }
        XCTAssertEqual(keychain.read(service: service, account: "acct"), "value-1")
        XCTAssertTrue(keychain.write("value-2", service: service, account: "acct"))
        XCTAssertEqual(keychain.read(service: service, account: "acct"), "value-2")
        keychain.delete(service: service, account: "acct")
        XCTAssertNil(keychain.read(service: service, account: "acct"))
    }
}
