import Foundation

// MARK: - TV control contract
// Every UI feature talks to a TV only through this protocol. Implementations:
//   * `LGTVClient` (WebOS/, real webOS TVs over SSAP)   — owned by the Connection agent
//   * `MockTV`     (Core/, simulator fixture + previews + tests)      — keep in sync when the protocol changes
// All methods are safe to call from the main actor; they hop off internally.

public protocol TVControlling: AnyObject, Sendable {
    var device: TVDevice { get }

    // Lifecycle
    /// Connects (and pairs if needed). Returns when connected. Updates `observeState()`.
    func connect() async throws
    func disconnect() async
    /// Call when the user types the PIN shown on the TV (state == .pairing(.enterPIN)).
    func submitPairingPIN(_ pin: String) async throws
    /// Each call returns a new stream; yields the current state immediately.
    func observeState() -> AsyncStream<ConnectionState>
    /// The device as last learned from the TV (model, MACs, secure socket preference...). Persist after connect.
    func refreshedDevice() async -> TVDevice

    // Buttons & pointer (pointer input socket)
    func press(_ key: RemoteKey) async throws
    func pointerMove(dx: Double, dy: Double, drag: Bool) async throws
    func pointerClick() async throws
    func pointerScroll(dx: Double, dy: Double) async throws

    // Audio
    func volumeUp() async throws
    func volumeDown() async throws
    func setVolume(_ value: Int) async throws
    func setMute(_ muted: Bool) async throws
    func volume() async throws -> VolumeState
    func observeVolume() -> AsyncStream<VolumeState>

    // Channels
    func channelUp() async throws
    func channelDown() async throws
    func channels() async throws -> [TVChannel]
    func setChannel(id: String) async throws
    func currentChannel() async throws -> TVChannel?

    // Apps & inputs
    func apps() async throws -> [TVApp]
    func launchApp(id: String, params: JSON?) async throws
    func foregroundAppID() async throws -> String?
    func observeForegroundApp() -> AsyncStream<String>
    func inputs() async throws -> [TVInput]
    func switchInput(id: String) async throws

    // Media
    func media(_ control: MediaControl) async throws
    /// Opens a photo or video URL (http on the LAN) in the TV's media viewer.
    func openMedia(url: URL, mimeType: String, title: String?, iconURL: URL?) async throws
    /// Closes media opened with `openMedia` (best effort).
    func closeMedia() async throws

    // Text input (IME)
    func insertText(_ text: String, replace: Bool) async throws
    func deleteCharacters(_ count: Int) async throws
    func sendEnter() async throws
    func observeKeyboard() -> AsyncStream<KeyboardState>

    // System
    func showToast(_ message: String) async throws
    func powerOff() async throws
    func screenOff() async throws
    func screenOn() async throws
    func info() async throws -> TVInfo
    func openURLInBrowser(_ url: URL) async throws
    /// Sets (minutes > 0) or cancels (nil / 0) a sleep timer. Implementations may use the TV's own timer or an
    /// app-side fallback; throw `LGError.unsupported` if neither is possible.
    func setSleepTimer(minutes: Int?) async throws
    /// Remaining sleep-timer minutes if known.
    func sleepTimerRemaining() async -> Int?
    /// Raw SSAP request escape hatch, e.g. ("ssap://audio/getVolume", nil).
    func request(_ uri: String, payload: JSON?) async throws -> JSON

    // Additive (Connection agent) — all have default implementations below, so existing conformers keep compiling.
    /// Like `connect()`, but when pairing is needed asks the TV to show a PIN (state `.pairing(.enterPIN)`, then
    /// `submitPairingPIN`) instead of an Accept/Deny prompt. TVs older than webOS 3.5 ignore this and prompt.
    func connect(preferPIN: Bool) async throws
    /// How `setSleepTimer` works on this TV, so the UI can explain its limits.
    var sleepTimerSupport: SleepTimerSupport { get }
    /// Downloads a TV-hosted resource such as `TVApp.iconURL` / `TVInput.iconURL`. Use this instead of
    /// `AsyncImage`: over wss the TV serves icons from `https://<tv>:3001` with a self-signed certificate that
    /// `URLSession.shared` rejects. Results are cached in memory.
    func resourceData(from url: URL) async throws -> Data
    /// Whether the picture is off (`screenOff()`): true = off, false = on. Yields the current value when known and
    /// follows changes made elsewhere, e.g. a key on the TV's own remote turning the picture back on. TVs that don't
    /// report it just reflect this app's own `screenOff()` / `screenOn()` calls.
    func observeScreenOff() -> AsyncStream<Bool>
}

/// How a sleep timer is implemented.
public enum SleepTimerSupport: Sendable, Hashable {
    /// The TV's own sleep timer is set; works even if the app is closed.
    case tvTimer
    /// The app turns the TV off when the time is up. Only works while the app stays open in the foreground
    /// (iOS suspends background apps); if the deadline was missed by more than a couple of minutes the timer is
    /// cancelled instead of switching the TV off unexpectedly later.
    case whileAppIsOpen
}

public extension TVControlling {
    func connect(preferPIN: Bool) async throws { try await connect() }
    var sleepTimerSupport: SleepTimerSupport { .whileAppIsOpen }
    func resourceData(from url: URL) async throws -> Data { try await URLSession.shared.data(from: url).0 }
    func observeScreenOff() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

// MARK: - Storage contract (Storage/ owned by Discovery agent)

public protocol DeviceStoring: Sendable {
    func loadDevices() -> [TVDevice]
    func saveDevices(_ devices: [TVDevice])
    func lastUsedDeviceID() -> String?
    func setLastUsedDeviceID(_ id: String?)
}

public protocol ClientKeyStoring: Sendable {
    func clientKey(for deviceID: String) -> String?
    func setClientKey(_ key: String?, for deviceID: String)
}

// MARK: - Discovery contract (Discovery/ owned by Discovery agent)

public protocol TVDiscovering: Sendable {
    /// Streams TVs as they are found until `timeout` elapses, then finishes. De-duplicated by id.
    func discover(timeout: TimeInterval) -> AsyncStream<TVDevice>
    /// Tries to reach a TV at an address typed by the user. Returns nil if no webOS TV answers.
    func probe(host: String) async -> TVDevice?
}

// MARK: - Factory

public enum TVClientFactory {
    /// Diagnostics sink for new clients' connection logs (the app sets it in debug builds).
    nonisolated(unsafe) public static var log: (@Sendable (String) -> Void)?

    public static func make(device: TVDevice, keyStore: ClientKeyStoring) -> any TVControlling {
        #if (DEBUG && targetEnvironment(simulator)) || os(macOS)
        if device.isDemo { return MockTV(device: device) }
        #endif
        return LGTVClient(device: device, keyStore: keyStore, log: log.map { l in { @Sendable message in l("ssap: " + message) } })
    }
}
