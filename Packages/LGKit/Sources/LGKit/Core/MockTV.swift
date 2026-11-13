#if (DEBUG && targetEnvironment(simulator)) || os(macOS)
import Foundation

/// In-memory TV used for simulator screenshots, SwiftUI previews and tests. Records every call in `log`.
public final class MockTV: TVControlling, @unchecked Sendable {
    public let device: TVDevice
    private let lock = NSLock()
    private var state: ConnectionState = .disconnected
    private var vol = VolumeState(volume: 3, muted: false, scenario: "mastervolume_tv_speaker")
    private var foreground = "com.webos.app.home"
    private var keyboard = KeyboardState(visible: false, currentText: "")
    private var stateConts: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var volConts: [UUID: AsyncStream<VolumeState>.Continuation] = [:]
    private var appConts: [UUID: AsyncStream<String>.Continuation] = [:]
    private var kbConts: [UUID: AsyncStream<KeyboardState>.Continuation] = [:]
    private var screenIsOff = false
    private var screenConts: [UUID: AsyncStream<Bool>.Continuation] = [:]
    public private(set) var log: [String] = []

    public init(device: TVDevice = .demo) { self.device = device }

    private func record(_ s: String) { lock.withLock { log.append(s) } }
    private func setState(_ s: ConnectionState) {
        let cs = lock.withLock { state = s; return Array(stateConts.values) }
        cs.forEach { $0.yield(s) }
    }
    private func setVolume(_ v: VolumeState) {
        let cs = lock.withLock { vol = v; return Array(volConts.values) }
        cs.forEach { $0.yield(v) }
    }
    private func setForeground(_ id: String) {
        let cs = lock.withLock { foreground = id; return Array(appConts.values) }
        cs.forEach { $0.yield(id) }
    }
    private func setKeyboard(_ k: KeyboardState) {
        let cs = lock.withLock { keyboard = k; return Array(kbConts.values) }
        cs.forEach { $0.yield(k) }
    }
    private func setScreenOff(_ off: Bool) {
        let cs = lock.withLock { () -> [AsyncStream<Bool>.Continuation] in
            guard screenIsOff != off else { return [] }
            screenIsOff = off; return Array(screenConts.values)
        }
        cs.forEach { $0.yield(off) }
    }
    private func stream<T>(_ current: T, _ store: ReferenceWritableKeyPath<MockTV, [UUID: AsyncStream<T>.Continuation]>) -> AsyncStream<T> {
        AsyncStream { c in
            let id = UUID()
            lock.withLock { self[keyPath: store][id] = c }
            c.yield(current)
            c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?[keyPath: store].removeValue(forKey: id) } }
        }
    }

    public func connect() async throws { record("connect"); setState(.connecting); try? await Task.sleep(for: .milliseconds(300)); setState(.connected) }
    public func disconnect() async { record("disconnect"); setState(.disconnected) }
    public func submitPairingPIN(_ pin: String) async throws { record("pin \(pin)") }
    public func observeState() -> AsyncStream<ConnectionState> { stream(lock.withLock { state }, \.stateConts) }
    public func refreshedDevice() async -> TVDevice { device }

    public func press(_ key: RemoteKey) async throws {
        record("press \(key.rawValue)")
        setScreenOff(false)  // like a real TV: any key brings the picture back
        switch key {
        case .volumeUp: try await volumeUp()
        case .volumeDown: try await volumeDown()
        case .mute: try await setMute(!lock.withLock { vol.muted })
        case .home: setForeground("com.webos.app.home")
        default: break
        }
    }
    public func pointerMove(dx: Double, dy: Double, drag: Bool) async throws { record("move \(Int(dx)),\(Int(dy))") }
    public func pointerClick() async throws { record("click") }
    public func pointerScroll(dx: Double, dy: Double) async throws { record("scroll \(Int(dx)),\(Int(dy))") }

    public func volumeUp() async throws { var v = lock.withLock { vol }; v.volume = min(100, v.volume + 1); setVolume(v) }
    public func volumeDown() async throws { var v = lock.withLock { vol }; v.volume = max(0, v.volume - 1); setVolume(v) }
    public func setVolume(_ value: Int) async throws { var v = lock.withLock { vol }; v.volume = max(0, min(100, value)); setVolume(v) }
    public func setMute(_ muted: Bool) async throws { var v = lock.withLock { vol }; v.muted = muted; setVolume(v) }
    public func volume() async throws -> VolumeState { lock.withLock { vol } }
    public func observeVolume() -> AsyncStream<VolumeState> { stream(lock.withLock { vol }, \.volConts) }

    public static let demoChannels = (1...12).map { TVChannel(id: "ch\($0)", number: "\($0)", name: "Channel \($0)") }
    public func channelUp() async throws { record("channelUp") }
    public func channelDown() async throws { record("channelDown") }
    public func channels() async throws -> [TVChannel] { Self.demoChannels }
    public func setChannel(id: String) async throws { record("channel \(id)"); setForeground("com.webos.app.livetv") }
    public func currentChannel() async throws -> TVChannel? { Self.demoChannels.first }

    public static let demoApps: [TVApp] = [
        TVApp(id: "netflix", title: "Netflix"), TVApp(id: "youtube.leanback.v4", title: "YouTube"),
        TVApp(id: "amazon", title: "Prime Video"), TVApp(id: "com.disney.disneyplus-prod", title: "Disney+"),
        TVApp(id: "com.apple.appletv", title: "Apple TV"), TVApp(id: "spotify-beehive", title: "Spotify"),
        TVApp(id: "com.webos.app.livetv", title: "Live TV"), TVApp(id: "com.webos.app.browser", title: "Web Browser"),
        TVApp(id: "com.webos.app.photovideo", title: "Photo & Video"), TVApp(id: "com.palm.app.settings", title: "Settings"),
    ]
    public func apps() async throws -> [TVApp] { Self.demoApps }
    public func launchApp(id: String, params: JSON?) async throws { record("launch \(id)"); setForeground(id) }
    public func foregroundAppID() async throws -> String? { lock.withLock { foreground } }
    public func observeForegroundApp() -> AsyncStream<String> { stream(lock.withLock { foreground }, \.appConts) }
    public static let demoInputs: [TVInput] = [
        TVInput(id: "HDMI_1", label: "HDMI 1", appId: "com.webos.app.hdmi1", connected: true),
        TVInput(id: "HDMI_2", label: "PlayStation", appId: "com.webos.app.hdmi2", connected: true),
        TVInput(id: "HDMI_3", label: "HDMI 3", appId: "com.webos.app.hdmi3"),
        TVInput(id: "HDMI_4", label: "HDMI 4", appId: "com.webos.app.hdmi4"),
        TVInput(id: "AV_1", label: "AV", appId: "com.webos.app.externalinput.av1"),
    ]
    public func inputs() async throws -> [TVInput] { Self.demoInputs }
    public func switchInput(id: String) async throws { record("input \(id)"); setForeground(Self.demoInputs.first { $0.id == id }?.appId ?? id) }

    public func media(_ control: MediaControl) async throws { record("media \(control.rawValue)") }
    public func openMedia(url: URL, mimeType: String, title: String?, iconURL: URL?) async throws { record("openMedia \(mimeType) \(url.absoluteString)") }
    public func closeMedia() async throws { record("closeMedia") }

    public func insertText(_ text: String, replace: Bool) async throws {
        record("text \(text) replace=\(replace)")
        var k = lock.withLock { keyboard }; k.currentText = replace ? text : (k.currentText ?? "") + text; setKeyboard(k)
    }
    public func deleteCharacters(_ count: Int) async throws {
        record("delete \(count)")
        var k = lock.withLock { keyboard }; k.currentText = String((k.currentText ?? "").dropLast(count)); setKeyboard(k)
    }
    public func sendEnter() async throws { record("enter") }
    public func observeKeyboard() -> AsyncStream<KeyboardState> { stream(lock.withLock { keyboard }, \.kbConts) }

    public func showToast(_ message: String) async throws { record("toast \(message)") }
    public func powerOff() async throws { record("powerOff"); setState(.disconnected) }
    public func screenOff() async throws { record("screenOff"); setScreenOff(true) }
    public func screenOn() async throws { record("screenOn"); setScreenOff(false) }
    public func observeScreenOff() -> AsyncStream<Bool> { stream(lock.withLock { screenIsOff }, \.screenConts) }
    public func info() async throws -> TVInfo { TVInfo(modelName: "Demo TV", webOSVersion: "Demo", firmwareVersion: "1.0", macAddresses: ["00:00:00:00:00:00"]) }
    public func openURLInBrowser(_ url: URL) async throws { record("browser \(url.absoluteString)"); setForeground("com.webos.app.browser") }
    private var sleepMinutes: Int?
    public func setSleepTimer(minutes: Int?) async throws { record("sleep \(minutes ?? 0)"); lock.withLock { sleepMinutes = (minutes ?? 0) > 0 ? minutes : nil } }
    public func sleepTimerRemaining() async -> Int? { lock.withLock { sleepMinutes } }
    public func request(_ uri: String, payload: JSON?) async throws -> JSON { record("request \(uri)"); return ["returnValue": true] }
}
#endif
