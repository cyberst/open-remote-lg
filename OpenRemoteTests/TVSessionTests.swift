import Testing
import LGKit
@testable import OpenRemote

@MainActor
struct TVSessionTests {
    private let realTV = TVDevice(id: "living-room", name: "Living Room", host: "192.168.1.20")

    private func session(store: InMemoryDeviceStore) -> TVSession {
        TVSession(store: store, keys: InMemoryKeyStore(), discovery: TVDiscovery())
    }

    @Test func removesLegacyDemoSelectionWithoutDeletingRealTVs() {
        let store = InMemoryDeviceStore(devices: [realTV, .demo])
        store.setLastUsedDeviceID(TVDevice.demo.id)
        let session = session(store: store)

        #expect(session.devices == [realTV])
        #expect(store.loadDevices() == [realTV])
        #expect(store.lastUsedDeviceID() == nil)
        #expect(session.lastUsedDevice == nil)
        #expect(!session.hasSetup)
        session.resume()
        #expect(session.current == nil)
    }

    @Test func clearsLegacyDemoSelectionEvenWhenItWasNeverSaved() {
        let store = InMemoryDeviceStore()
        store.setLastUsedDeviceID(TVDevice.demo.id)
        let session = session(store: store)

        #expect(store.lastUsedDeviceID() == nil)
        #expect(!session.hasSetup)
    }

    @Test func preservesRealTVSelectionAndPairingKey() {
        let store = InMemoryDeviceStore(devices: [.demo, realTV])
        store.setLastUsedDeviceID(realTV.id)
        let keys = InMemoryKeyStore()
        keys.setClientKey("paired-key", for: realTV.id)
        let session = TVSession(store: store, keys: keys, discovery: TVDiscovery())

        #expect(session.lastUsedDevice == realTV)
        #expect(session.hasSetup)
        #expect(store.loadDevices() == [realTV])
        #expect(keys.clientKey(for: realTV.id) == "paired-key")
    }

    @Test func fixtureCannotOverwriteSavedTVOrSelection() {
        let store = InMemoryDeviceStore(devices: [realTV])
        store.setLastUsedDeviceID(realTV.id)
        let session = session(store: store)
        session.remember(.demo)

        #expect(store.loadDevices() == [realTV])
        #expect(store.lastUsedDeviceID() == realTV.id)
    }

    @Test func demoLaunchFlagIsRestrictedToDebugSimulator() {
        #expect(!LaunchOptions(arguments: []).demo)
        let options = LaunchOptions(arguments: ["-demo"])
        #if DEBUG && targetEnvironment(simulator)
        #expect(options.demo)
        #else
        #expect(!options.demo)
        #expect(TVClientFactory.make(device: .demo, keyStore: InMemoryKeyStore()) is LGTVClient)
        #endif
    }
}
