import Foundation

/// Simple thread-safe in-memory stores for tests / previews.
public final class InMemoryDeviceStore: DeviceStoring, @unchecked Sendable {
    private let lock = NSLock(); private var devices: [TVDevice] = []; private var last: String?
    public init(devices: [TVDevice] = []) { self.devices = devices }
    public func loadDevices() -> [TVDevice] { lock.withLock { devices } }
    public func saveDevices(_ d: [TVDevice]) { lock.withLock { devices = d } }
    public func lastUsedDeviceID() -> String? { lock.withLock { last } }
    public func setLastUsedDeviceID(_ id: String?) { lock.withLock { last = id } }
}

public final class InMemoryKeyStore: ClientKeyStoring, @unchecked Sendable {
    private let lock = NSLock(); private var keys: [String: String] = [:]
    public init() {}
    public func clientKey(for id: String) -> String? { lock.withLock { keys[id] } }
    public func setClientKey(_ key: String?, for id: String) { lock.withLock { keys[id] = key } }
}
