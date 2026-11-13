import Foundation

/// Controls a real LG webOS TV (webOS 1.x, 2014 → webOS 25) over SSAP.
///
/// * Connects over `wss://host:3001` and/or `ws://host:3000` (whichever works; remembered in `refreshedDevice()`).
/// * Pairs with an on-TV prompt (default) or a PIN (`connect(preferPIN: true)`); the client key goes to `keyStore`.
/// * Reconnects automatically with backoff after drops and re-establishes subscriptions.
/// * Remote-control buttons, pointer and scroll go over the TV's pointer-input socket.
public final class LGTVClient: TVControlling, @unchecked Sendable {
    public let device: TVDevice
    let keyStore: ClientKeyStoring

    private let engine: SSAPEngine
    private let pointer: PointerChannel
    private let stateOut = Broadcaster<ConnectionState>(.disconnected)
    private let volumeOut = Broadcaster<VolumeState>()
    private let foregroundOut = Broadcaster<String>()
    private let keyboardOut = Broadcaster<KeyboardState>()
    private let screenOffOut = Broadcaster<Bool>()
    private let lock = NSLock()
    private var cachedInfo: TVInfo?
    private var mediaSessionID: String?
    private let sleepTimer: AppSleepTimer
    private let resources: TVResourceLoader

    public convenience init(device: TVDevice, keyStore: ClientKeyStoring) {
        self.init(device: device, keyStore: keyStore, log: nil)
    }

    /// `log` receives raw protocol traffic and diagnostics (used by `lgctl --verbose`).
    public convenience init(device: TVDevice, keyStore: ClientKeyStoring, log: (@Sendable (String) -> Void)?) {
        self.init(device: device, keyStore: keyStore, factory: URLSessionTransportFactory(), timing: SSAPTiming(), log: log)
    }

    init(device: TVDevice, keyStore: ClientKeyStoring, factory: WebSocketTransportFactory, timing: SSAPTiming,
         log: (@Sendable (String) -> Void)? = nil, prewarmPointer: Bool = true) {
        self.device = device
        self.keyStore = keyStore
        let pointerRef = WeakRef<PointerChannel>()
        let engine = SSAPEngine(host: device.host, deviceID: device.id, secure: device.useSecureSocket, keyStore: keyStore,
                                factory: factory, timing: timing, stateOut: stateOut, log: log,
                                onConnected: {
                                    // Pointer URLs die with the old session. Re-open right away so the first button
                                    // press doesn't pay for the handshake (wss TLS on TVs can take ~0.5 s).
                                    guard let pointer = pointerRef.value else { return }
                                    await pointer.reset()
                                    if prewarmPointer { Task { await pointer.prewarm() } }
                                })
        self.engine = engine
        self.pointer = PointerChannel(factory: factory, connectTimeout: timing.connectTimeout, log: log) {
            try await engine.pointerSocketURL()
        }
        pointerRef.value = pointer
        resources = TVResourceLoader(host: device.host)
        let me = WeakRef<LGTVClient>()
        sleepTimer = AppSleepTimer(
            key: device.id,
            warn: { try? await me.value?.showToast("Sleep timer: the TV turns off in 1 minute.") },
            fire: { try? await me.value?.powerOff() })
        me.value = self
        sleepTimer.resume()
    }

    deinit {
        let engine = self.engine, pointer = self.pointer
        Task { await engine.disconnect(); await pointer.reset() }
        sleepTimer.suspend()
        [stateOut.finishAll, volumeOut.finishAll, foregroundOut.finishAll, keyboardOut.finishAll].forEach { $0() }
    }

    // MARK: - Lifecycle

    public func connect() async throws { try await connect(preferPIN: false) }

    public func connect(preferPIN: Bool) async throws {
        try await engine.connect(preferPIN: preferPIN)
    }

    public func disconnect() async {
        await engine.disconnect()
        await pointer.reset()
    }

    public func submitPairingPIN(_ pin: String) async throws { try await engine.submitPIN(pin) }

    public func observeState() -> AsyncStream<ConnectionState> { stateOut.stream() }

    public func refreshedDevice() async -> TVDevice {
        var d = device
        if let secure = await engine.securePreference { d.useSecureSocket = secure }
        let live: TVInfo? = await engine.isUp ? try? await info() : nil
        if let info = live ?? lock.withLock({ cachedInfo }) {
            if let m = info.modelName { d.modelName = m }
            if let v = info.webOSVersion { d.webOSVersion = v }
            if !info.macAddresses.isEmpty { d.macAddresses = info.macAddresses }
            if let name = info.deviceName, d.name.isEmpty || d.name == d.host { d.name = name }
        }
        return d
    }

    public var sleepTimerSupport: SleepTimerSupport { .whileAppIsOpen }

    // MARK: - Buttons & pointer

    public func press(_ key: RemoteKey) async throws {
        switch key {
        // The SSAP audio calls work even when another app holds the pointer socket and report errors properly.
        case .volumeUp: try await volumeUp()
        case .volumeDown: try await volumeDown()
        default: try await pointer.button(key.rawValue)
        }
    }

    public func pointerMove(dx: Double, dy: Double, drag: Bool) async throws { try await pointer.move(dx: dx, dy: dy, drag: drag) }
    public func pointerClick() async throws { try await pointer.click() }
    public func pointerScroll(dx: Double, dy: Double) async throws { try await pointer.scroll(dx: dx, dy: dy) }

    // MARK: - Audio

    public func volumeUp() async throws { _ = try await request("ssap://audio/volumeUp", payload: nil) }
    public func volumeDown() async throws { _ = try await request("ssap://audio/volumeDown", payload: nil) }

    public func setVolume(_ value: Int) async throws {
        _ = try await request("ssap://audio/setVolume", payload: ["volume": .number(Double(max(0, min(100, value))))])
    }

    public func setMute(_ muted: Bool) async throws {
        _ = try await request("ssap://audio/setMute", payload: ["mute": .bool(muted)])
    }

    public func volume() async throws -> VolumeState {
        let p = try await request("ssap://audio/getVolume", payload: nil)
        guard let v = SSAPParsers.volume(p) else { throw LGError.tvError("Unexpected volume response.") }
        volumeOut.sendIfChanged(v)
        return v
    }

    public func observeVolume() -> AsyncStream<VolumeState> {
        ensureSubscription(key: "volume", uri: "ssap://audio/getVolume") { [weak self] p in
            if let v = SSAPParsers.volume(p) { self?.volumeOut.sendIfChanged(v) }
        }
        return volumeOut.stream()
    }

    // MARK: - Channels

    public func channelUp() async throws { _ = try await request("ssap://tv/channelUp", payload: nil) }
    public func channelDown() async throws { _ = try await request("ssap://tv/channelDown", payload: nil) }

    public func channels() async throws -> [TVChannel] {
        SSAPParsers.channels(try await request("ssap://tv/getChannelList", payload: nil, timeout: 15))
    }

    public func setChannel(id: String) async throws {
        _ = try await request("ssap://tv/openChannel", payload: ["channelId": .string(id)])
    }

    public func currentChannel() async throws -> TVChannel? {
        SSAPParsers.channel(try await request("ssap://tv/getCurrentChannel", payload: nil))
    }

    // MARK: - Apps & inputs

    public func apps() async throws -> [TVApp] {
        do {
            let apps = SSAPParsers.apps(try await request("ssap://com.webos.applicationManager/listLaunchPoints", payload: nil, timeout: 15),
                                        host: device.host)
            if !apps.isEmpty { return apps }
        } catch LGError.timeout {
            throw LGError.timeout
        } catch {
            // Fall through to listApps (older firmware / restricted launch points).
        }
        return SSAPParsers.apps(try await request("ssap://com.webos.applicationManager/listApps", payload: nil, timeout: 15),
                                host: device.host)
    }

    public func launchApp(id: String, params: JSON?) async throws {
        var p: [String: JSON] = ["id": .string(id)]
        if let params { p["params"] = params }
        _ = try await request("ssap://system.launcher/launch", payload: .object(p))
    }

    public func foregroundAppID() async throws -> String? {
        let id = SSAPParsers.foregroundApp(try await request("ssap://com.webos.applicationManager/getForegroundAppInfo", payload: nil))
        if let id, !id.isEmpty { foregroundOut.sendIfChanged(id) }
        return id
    }

    public func observeForegroundApp() -> AsyncStream<String> {
        ensureSubscription(key: "foreground", uri: "ssap://com.webos.applicationManager/getForegroundAppInfo") { [weak self] p in
            if let id = SSAPParsers.foregroundApp(p), !id.isEmpty { self?.foregroundOut.sendIfChanged(id) }
        }
        return foregroundOut.stream()
    }

    public func inputs() async throws -> [TVInput] {
        SSAPParsers.inputs(try await request("ssap://tv/getExternalInputList", payload: nil), host: device.host)
    }

    public func switchInput(id: String) async throws {
        _ = try await request("ssap://tv/switchInput", payload: ["inputId": .string(id)])
    }

    // MARK: - Media

    public func media(_ control: MediaControl) async throws {
        let method: String
        switch control {
        case .play: method = "play"
        case .pause: method = "pause"
        case .stop: method = "stop"
        case .rewind: method = "rewind"
        case .fastForward: method = "fastForward"
        }
        _ = try await request("ssap://media.controls/\(method)", payload: nil)
    }

    public func openMedia(url: URL, mimeType: String, title: String?, iconURL: URL?) async throws {
        var p: [String: JSON] = [
            "target": .string(url.absoluteString),
            "mimeType": .string(mimeType),
            "title": .string(title ?? url.lastPathComponent),
            "description": "",
        ]
        if let iconURL { p["iconSrc"] = .string(iconURL.absoluteString) }
        let r = try await request("ssap://media.viewer/open", payload: .object(p))
        lock.withLock { mediaSessionID = r["sessionId"]?.stringValue }
    }

    public func closeMedia() async throws {
        guard let session = lock.withLock({ mediaSessionID }) else { return }
        _ = try await request("ssap://media.viewer/close", payload: ["sessionId": .string(session)])
        lock.withLock { if mediaSessionID == session { mediaSessionID = nil } }
    }

    // MARK: - Text input (IME)

    public func insertText(_ text: String, replace: Bool) async throws {
        _ = try await request("ssap://com.webos.service.ime/insertText", payload: ["text": .string(text), "replace": .number(replace ? 1 : 0)])
    }

    public func deleteCharacters(_ count: Int) async throws {
        guard count > 0 else { return }
        _ = try await request("ssap://com.webos.service.ime/deleteCharacters", payload: ["count": .number(Double(count))])
    }

    public func sendEnter() async throws { _ = try await request("ssap://com.webos.service.ime/sendEnterKey", payload: nil) }

    public func observeKeyboard() -> AsyncStream<KeyboardState> {
        ensureSubscription(key: "keyboard", uri: "ssap://com.webos.service.ime/registerRemoteKeyboard") { [weak self] p in
            if let k = SSAPParsers.keyboard(p) { self?.keyboardOut.sendIfChanged(k) }
        }
        return keyboardOut.stream()
    }

    // MARK: - System

    public func showToast(_ message: String) async throws {
        _ = try await request("ssap://system.notifications/createToast", payload: ["message": .string(message)])
    }

    public func powerOff() async throws {
        _ = try await request("ssap://system/turnOff", payload: nil)
    }

    public func screenOff() async throws {
        try await firstSupported([
            ("ssap://com.webos.service.tvpower/power/turnOffScreen", ["standbyMode": "active"]), // webOS 4.5+
            ("ssap://com.webos.service.tv.power/turnOffScreen", nil),                           // older firmware
        ])
        screenOffOut.sendIfChanged(true)
    }

    public func screenOn() async throws {
        do {
            try await firstSupported([
                ("ssap://com.webos.service.tvpower/power/turnOnScreen", ["standbyMode": "active"]),
                ("ssap://com.webos.service.tv.power/turnOnScreen", nil),
            ])
        } catch let e as LGError where Self.isUnsupported(e) {
            // Firmware without a screen-on call: any remote key brings the picture back (checked on a webOS 4.5 set
            // over the pointer socket). INFO is the harmless choice in case the TV also acts on the key — at worst a
            // short info banner, where a digit would tune a channel in live TV and an arrow would seek a video.
            try await press(.info)
        }
        screenOffOut.sendIfChanged(false)
    }

    public func observeScreenOff() -> AsyncStream<Bool> {
        ensureSubscription(key: "power", uri: "ssap://com.webos.service.tvpower/power/getPowerState") { [weak self] p in
            if let off = SSAPParsers.screenOff(p) { self?.screenOffOut.sendIfChanged(off) }
        }
        return screenOffOut.stream()
    }

    public func info() async throws -> TVInfo {
        async let system = try? request("ssap://system/getSystemInfo", payload: nil)
        async let software = try? request("ssap://com.webos.service.update/getCurrentSWInformation", payload: nil)
        async let network = try? request("ssap://com.webos.service.connectionmanager/getinfo", payload: nil)
        async let name = try? request("ssap://settings/getSystemSettings", payload: ["category": "network", "keys": ["deviceName"]])
        let (sys, sw, net, nm) = await (system, software, network, name)
        guard sys != nil || sw != nil || net != nil else {
            if await engine.isUp { throw LGError.tvError("The TV did not return system information.") }
            throw LGError.notConnected
        }
        var info = TVInfo()
        info.modelName = sys?["modelName"]?.stringValue
        if let sys {
            if let receiver = sys["receiverType"]?.stringValue { info.extra["receiverType"] = receiver }
            if let features = sys["features"]?.objectValue {
                for (k, v) in features { if let b = v.boolValue { info.extra["feature.\(k)"] = b ? "true" : "false" } }
            }
        }
        if let sw {
            let s = SSAPParsers.softwareInfo(sw)
            info.webOSVersion = s.webOSVersion
            info.firmwareVersion = s.firmwareVersion
            info.extra.merge(s.extra) { a, _ in a }
        }
        if info.webOSVersion == nil, let model = info.modelName, let guess = SSAPParsers.estimatedWebOSVersion(modelName: model) {
            info.webOSVersion = guess
            info.extra["webOSVersionSource"] = "estimated from model year"
        }
        if let net { info.macAddresses = SSAPParsers.macAddresses(net) }
        if let nm { info.deviceName = SSAPParsers.deviceName(nm) }
        if let secure = await engine.socketIsSecure { info.extra["connection"] = secure ? "wss:3001" : "ws:3000" }
        lock.withLock { cachedInfo = info }
        return info
    }

    public func openURLInBrowser(_ url: URL) async throws {
        _ = try await request("ssap://system.launcher/open", payload: ["target": .string(url.absoluteString)])
    }

    public func setSleepTimer(minutes: Int?) async throws {
        sleepTimer.set(minutes: minutes)
        if let m = minutes, m > 0 {
            try? await showToast("Sleep timer: the TV turns off in \(m) min while Open Remote stays open.")
        }
    }

    public func sleepTimerRemaining() async -> Int? { sleepTimer.remainingMinutes }

    public func request(_ uri: String, payload: JSON?) async throws -> JSON {
        try await request(uri, payload: payload, timeout: nil)
    }

    public func resourceData(from url: URL) async throws -> Data { try await resources.data(from: url) }

    func request(_ uri: String, payload: JSON?, timeout: TimeInterval?) async throws -> JSON {
        try await engine.request(Self.normalizedURI(uri), payload: payload, timeout: timeout)
    }

    /// Debug: drops the live socket as if Wi-Fi vanished, to exercise auto-reconnect (used by `lgctl drop`).
    @_spi(Debug) public func simulateNetworkDrop() async { await engine.simulateDrop() }

    // MARK: - Helpers

    /// Set-once weak reference used to break init-order cycles.
    private final class WeakRef<T: AnyObject>: @unchecked Sendable { weak var value: T? }

    static func normalizedURI(_ uri: String) -> String {
        uri.hasPrefix("ssap://") || uri.hasPrefix("luna://") ? uri : "ssap://" + uri
    }

    private func ensureSubscription(key: String, uri: String, handler: @escaping @Sendable (JSON) -> Void) {
        let engine = self.engine
        Task { await engine.subscribe(key: key, uri: uri, payload: nil, handler: handler) }
    }

    /// Tries URIs in order, skipping ones the TV doesn't know (404) or doesn't allow (401).
    private func firstSupported(_ calls: [(String, JSON?)]) async throws {
        var lastError: Error = LGError.unsupported("this feature")
        for (uri, payload) in calls {
            do { _ = try await request(uri, payload: payload); return } catch let e as LGError {
                lastError = e
                if Self.isUnsupported(e) { continue }
                throw e
            }
        }
        throw lastError
    }

    /// The TV doesn't know the call (404 / "no such service") or doesn't allow it (401).
    private static func isUnsupported(_ e: LGError) -> Bool {
        switch e {
        case .unsupported: true
        case .tvError(let m): m.hasPrefix("401") || m.lowercased().contains("no such")
        default: false
        }
    }
}
