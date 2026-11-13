import Foundation
import Security

// MARK: - Saved TVs

/// Saved TVs + last used id in one versioned JSON file in Application Support.
/// Reads are served from memory; writes are atomic and happen on a private serial queue (call `flush()` to wait).
/// A corrupt file is moved aside to `<name>.corrupt` and the store starts empty; individual undecodable
/// entries are skipped rather than failing the whole file.
public final class FileDeviceStore: DeviceStoring, @unchecked Sendable {
    public static let formatVersion = 1
    public let fileURL: URL

    private let lock = NSLock()
    private var devices: [TVDevice] = []
    private var lastUsed: String?
    private let ioQueue = DispatchQueue(label: "com.simber.openremoteforlg.devicestore", qos: .utility)

    public convenience init() { self.init(fileURL: Self.defaultFileURL()) }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let (devices, lastUsed) = Self.read(fileURL)
        self.devices = devices
        self.lastUsed = lastUsed
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenRemote", isDirectory: true).appendingPathComponent("devices.json")
    }

    public func loadDevices() -> [TVDevice] { lock.withLock { devices } }

    public func saveDevices(_ newDevices: [TVDevice]) {
        lock.withLock { devices = newDevices; enqueueWriteLocked() }
    }

    public func lastUsedDeviceID() -> String? { lock.withLock { lastUsed } }

    public func setLastUsedDeviceID(_ id: String?) {
        lock.withLock { lastUsed = id; enqueueWriteLocked() }
    }

    /// Blocks until every pending write has reached disk.
    public func flush() { ioQueue.sync {} }

    // MARK: File format

    struct FileContents: Codable {
        var version: Int
        var devices: [TVDevice]
        var lastUsedDeviceID: String?

        init(version: Int, devices: [TVDevice], lastUsedDeviceID: String?) {
            self.version = version; self.devices = devices; self.lastUsedDeviceID = lastUsedDeviceID
        }

        enum CodingKeys: String, CodingKey { case version, devices, lastUsedDeviceID }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            lastUsedDeviceID = try? c.decodeIfPresent(String.self, forKey: .lastUsedDeviceID)
            var list: [TVDevice] = []
            if var items = try? c.nestedUnkeyedContainer(forKey: .devices) {
                while !items.isAtEnd {
                    if let device = try? items.decode(TVDevice.self) {
                        list.append(device)
                    } else if (try? items.decode(JSON.self)) == nil {
                        break // can't advance past this element
                    }
                }
            }
            devices = list
        }
    }

    /// Must hold `lock`: snapshotting and enqueueing together keeps disk writes in the same order as mutations.
    private func enqueueWriteLocked() {
        let snapshot = FileContents(version: Self.formatVersion, devices: devices, lastUsedDeviceID: lastUsed)
        let url = fileURL
        ioQueue.async { Self.write(snapshot, to: url) }
    }

    static func read(_ url: URL) -> ([TVDevice], String?) {
        guard let data = try? Data(contentsOf: url) else { return ([], nil) }
        do {
            let contents = try JSONDecoder().decode(FileContents.self, from: data)
            return (contents.devices, contents.lastUsedDeviceID)
        } catch {
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return ([], nil)
        }
    }

    static func write(_ contents: FileContents, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(contents)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Keeping the in-memory copy is the best we can do; the next save retries.
        }
    }
}

// MARK: - Pairing keys

/// Storage backend for `KeychainKeyStore`, injectable for tests.
public protocol SecretBackend: Sendable {
    func read(service: String, account: String) -> String?
    /// Returns false if the value could not be stored.
    @discardableResult func write(_ value: String, service: String, account: String) -> Bool
    func delete(service: String, account: String)
}

/// The system Keychain: generic passwords readable after first unlock (so reconnects work
/// from the background), never synced to iCloud.
public struct SystemKeychain: SecretBackend {
    public init() {}

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query(service, account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(service, account)
        add.merge(attributes) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// Pairing client keys, one Keychain item per TV (account = device id).
/// Keys are cached in memory, so a TV paired while the Keychain is unavailable still works for this session.
public final class KeychainKeyStore: ClientKeyStoring, @unchecked Sendable {
    public static let defaultService = "com.simber.openremoteforlg.clientkey"

    private let service: String
    private let backend: any SecretBackend
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init(service: String = KeychainKeyStore.defaultService, backend: any SecretBackend = SystemKeychain()) {
        self.service = service
        self.backend = backend
    }

    public func clientKey(for deviceID: String) -> String? {
        if let cached = lock.withLock({ cache[deviceID] }) { return cached }
        guard let key = backend.read(service: service, account: deviceID), !key.isEmpty else { return nil }
        lock.withLock { cache[deviceID] = key }
        return key
    }

    public func setClientKey(_ key: String?, for deviceID: String) {
        if let key, !key.isEmpty {
            lock.withLock { cache[deviceID] = key }
            backend.write(key, service: service, account: deviceID)
        } else {
            lock.withLock { cache[deviceID] = nil }
            backend.delete(service: service, account: deviceID)
        }
    }
}
