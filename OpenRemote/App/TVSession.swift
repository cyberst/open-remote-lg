import SwiftUI
import LGKit

/// App-wide state: saved TVs, the active TV connection, and its connection state.
/// Feature views read it with `@Environment(TVSession.self) private var session`
/// and send commands with `session.send { try await $0.press(.home) }`.
@MainActor
@Observable
final class TVSession {
    let store: DeviceStoring
    let keys: ClientKeyStoring
    let discovery: TVDiscovering

    var devices: [TVDevice]
    /// The TV the remote is pointed at. Set immediately when a connection starts so controls can show right away.
    private(set) var current: TVDevice?
    private(set) var tv: (any TVControlling)?
    private(set) var state: ConnectionState = .disconnected
    /// Last user-visible error (cleared on next successful command). UI shows it as a transient banner.
    var lastError: String?

    /// True while `connect(to:)` is in flight (before the client reports its own state).
    private(set) var isConnecting = false
    /// True while powering the TV on (Wake-on-LAN + connection retries).
    private(set) var isWaking = false
    /// The last connection attempt found nothing answering at the TV's address: it's most likely switched off
    /// (standby). Shown as "TV is off" rather than an error; the status line then offers to turn it on.
    private(set) var appearsOff = false
    /// TVs streamed in by the most recent discovery run.
    private(set) var discovered: [TVDevice] = []
    private(set) var isDiscovering = false
    /// Whether the user has completed setup at least once (a last-used TV exists). Drives onboarding.
    private(set) var hasSetup = false

    private var stateTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    /// Incremented for every connection attempt so late results from superseded attempts are ignored.
    private var generation = 0
    @ObservationIgnored private var sendsAwaitingConnection = 0
    /// Debug diagnostics sink (set by `-wakeLog`).
    @ObservationIgnored var diagnostics: (@Sendable (String) -> Void)?

    init(store: DeviceStoring, keys: ClientKeyStoring, discovery: TVDiscovering) {
        self.store = store; self.keys = keys; self.discovery = discovery
        let saved = store.loadDevices()
        self.devices = saved.filter { !$0.isDemo && $0.id != TVDevice.demo.id }
        // Older builds persisted the demo selection. Remove it on upgrade in every configuration.
        if devices != saved { store.saveDevices(devices) }
        if let id = store.lastUsedDeviceID(),
           id == TVDevice.demo.id || saved.contains(where: { $0.id == id && $0.isDemo }) {
            store.setLastUsedDeviceID(nil)
        }
        self.hasSetup = lastUsedDevice != nil
    }

    static func live() -> TVSession {
        TVSession(store: FileDeviceStore(), keys: KeychainKeyStore(), discovery: TVDiscovery())
    }

    static func preview(connected: Bool = true) -> TVSession {
        let living = TVDevice(id: "preview-1", name: "Living Room", host: "192.168.1.20", macAddresses: ["A8:23:FE:00:11:22"],
                              modelName: "OLED55C3", webOSVersion: "23")
        let s = TVSession(store: InMemoryDeviceStore(devices: [living]), keys: InMemoryKeyStore(), discovery: TVDiscovery())
        #if DEBUG && targetEnvironment(simulator)
        if connected { s.startDemo() }
        #endif
        return s
    }

    var isConnected: Bool { state.isConnected }

    /// Key for `.task(id:)` blocks that observe `tv`: changes when the TV changes or the connection drops and
    /// comes back (the client is replaced after backgrounding), so those observers restart on the live client.
    var observationKey: String { "\(current?.id ?? "")|\(isConnected)" }

    /// The pairing prompt currently shown on the TV, if any.
    var pairingRequest: PairingRequest? {
        if case .pairing(let r) = state { return r }
        // Keeps the pairing sheet up while `pairWithPIN()` reconnects, instead of closing and reopening it.
        return switchingToPIN && state == .connecting ? .enterPIN : nil
    }
    private var switchingToPIN = false

    /// How the current TV implements the sleep timer (the UI explains `.whileAppIsOpen`).
    var sleepTimerSupport: SleepTimerSupport { tv?.sleepTimerSupport ?? .whileAppIsOpen }

    var lastUsedDevice: TVDevice? {
        guard let id = store.lastUsedDeviceID() else { return nil }
        return devices.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Called on launch and whenever the app becomes active: (re)connects to the last used TV.
    /// Idempotent — does nothing while already connected or connecting.
    func resume() {
        diagnostics?("resume() connected=\(isConnected) connecting=\(isConnecting) waking=\(isWaking) state=\(state)")
        if isConnected || isConnecting || isWaking { return }
        if case .pairing = state { return }
        guard let device = current ?? lastUsedDevice else { return }
        current = device  // synchronously, so the remote renders on the first frame
        isConnecting = true
        // Quiet: a TV that's off isn't an error; the status line shows "TV is off · Tap to turn on".
        Task { await connect(to: device, reportErrors: false) }
    }

    /// Disconnects when the app goes to the background but keeps `current`, so the UI stays put.
    /// State changes synchronously so a quick background → active bounce can't race `resume()`.
    func suspend() {
        diagnostics?("suspend() — app went to background; waking=\(isWaking)")
        generation += 1
        stateTask?.cancel(); stateTask = nil
        stopDiscovery()
        let client = tv
        tv = nil; isConnecting = false; isWaking = false; switchingToPIN = false; state = .disconnected
        Task { await client?.disconnect() }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Opt-in fixture for simulator screenshots and previews; never persisted as a user's TV.
    func startDemo() {
        current = .demo
        hasSetup = true
        Task { await connect(to: .demo) }
    }
    #endif

    /// Connects to `device` (disconnecting any current TV). Saves the device on success.
    /// If a saved TV can't be reached, runs a short discovery in case it moved to a new IP, then retries once.
    /// `preferPIN` asks the TV to show a PIN instead of an Accept prompt when pairing is needed (webOS 3.5+).
    func connect(to device: TVDevice, preferPIN: Bool = false, rediscoverOnFailure: Bool = true, reportErrors: Bool = true) async {
        #if !(DEBUG && targetEnvironment(simulator))
        guard !device.isDemo, device.id != TVDevice.demo.id else { return }
        #endif
        generation += 1
        let gen = generation
        stateTask?.cancel()
        if let old = tv { await old.disconnect() }
        guard gen == generation else { return }

        let t0 = ContinuousClock.now
        let diag = diagnostics
        diag?("connect gen=\(gen) host=\(device.host) rediscover=\(rediscoverOnFailure) start")
        defer { diag?("connect gen=\(gen) end after \(ContinuousClock.now - t0) connected=\(isConnected) superseded=\(gen != generation)") }
        let client = TVClientFactory.make(device: device, keyStore: keys)
        tv = client; current = device; lastError = nil; isConnecting = true; state = .connecting
        stateTask = Task { [weak self] in
            for await s in client.observeState() {
                guard let self, self.generation == gen else { break }
                self.state = s
            }
        }
        do {
            // Fail fast (≈1 s) for a TV that is off or has moved, instead of waiting out the socket timeout.
            if !device.isDemo, await !TVReachability.isReachable(host: device.host) {
                diag?("connect gen=\(gen) reachability: unreachable")
                throw UnreachableTV(name: device.name)
            }
            diag?("connect gen=\(gen) reachability: reachable; opening SSAP")
            guard gen == generation else { return }
            try await client.connect(preferPIN: preferPIN)
            guard gen == generation else { return }
            isConnecting = false
            appearsOff = false
            if state != .connected { state = .connected }
            var d = await client.refreshedDevice()
            d.lastConnected = .now
            remember(d)
            Haptics.success()
        } catch {
            guard gen == generation else { return }
            isConnecting = false
            appearsOff = error is UnreachableTV
            if state.isConnected || state == .connecting { state = .failed(error.localizedDescription) }
            diag?("connect gen=\(gen) failed: \(error)")
            if rediscoverOnFailure, !device.isDemo, let moved = await locateMoved(device), gen == generation {
                await connect(to: moved, preferPIN: preferPIN, rediscoverOnFailure: false, reportErrors: reportErrors)
                return
            }
            // A TV that doesn't answer is shown as "TV is off" by the status line (and key presses say so), not as an error.
            if reportErrors, !(error is UnreachableTV) { report(error) }
        }
    }

    /// Reconnects to the current TV (status pill "tap to retry", commands while offline).
    func reconnect() {
        guard let device = current, !isConnecting, !isWaking else { return }
        Task { await connect(to: device) }
    }

    /// The status line's action: turn the TV on if it looks off, otherwise try connecting again.
    func retryOrTurnOn() {
        if appearsOff, !isWaking { _ = pressPower() } else { reconnect() }
    }

    /// Stops talking to the TV and clears the selection (e.g. after forgetting it).
    func disconnect() async {
        generation += 1
        stateTask?.cancel(); stateTask = nil
        let client = tv
        tv = nil; current = nil; isConnecting = false; state = .disconnected
        await client?.disconnect()
    }

    func submitPairingPIN(_ pin: String) async {
        guard let tv else { return }
        do { try await tv.submitPairingPIN(pin) } catch { report(error) }
    }

    /// User dismissed the pairing prompt in the app.
    func cancelPairing() {
        guard pairingRequest != nil else { return }
        suspend()
    }

    /// Restarts pairing with a PIN shown on the TV instead of the Accept prompt (e.g. the prompt was dismissed).
    func pairWithPIN() {
        guard let device = current, pairingRequest == .acceptOnTV else { return }
        switchingToPIN = true
        Task {
            await connect(to: device, preferPIN: true)
            switchingToPIN = false
        }
    }

    // MARK: - Power

    /// Turns the TV on: Wake-on-LAN (re-sent every ~3 s), polling every ~0.5 s and connecting the moment the TV
    /// answers, for up to ~30 s while it boots. Halfway through, one discovery pass looks for a changed IP.
    func powerOn() async {
        guard let device = current, !isWaking else { return }
        if device.isDemo { await connect(to: device); return }
        isWaking = true
        defer { isWaking = false }
        lastError = nil
        if device.macAddresses.isEmpty {
            lastError = "Turn the TV on with its own remote once while Open Remote is connected, so the app can learn how to wake it."
        }
        let start = ContinuousClock.now
        let deadline = start + .seconds(30)
        var lastWake = start - .seconds(10)
        var searchedForNewIP = false
        // `isWaking` is cleared by `suspend()`, which also stops this loop.
        while isWaking, ContinuousClock.now < deadline, current?.id == device.id {
            let target = current ?? device
            if ContinuousClock.now - lastWake >= .seconds(3) {
                lastWake = .now
                let macs = target.macAddresses, host = target.host
                Task.detached { await WakeOnLAN.wake(macAddresses: macs, lastKnownHost: host) }
            }
            if await TVReachability.isReachable(host: target.host, timeout: 0.6) {
                diagnostics?("powerOn: TV answers after \(ContinuousClock.now - start); connecting")
                await connect(to: target, rediscoverOnFailure: false, reportErrors: false)
                diagnostics?("powerOn: connect finished, state=\(state)")
                if isConnected { return }
            } else if !searchedForNewIP, ContinuousClock.now - start > .seconds(10) {
                searchedForNewIP = true
                if let moved = await locateMoved(target), isWaking {
                    diagnostics?("powerOn: TV moved to \(moved.host)")
                    current = moved
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !isConnected, isWaking {
            report(message: "\(device.name) didn't turn on. Check that it's plugged in, on the same Wi‑Fi, and that “Turn on via Wi‑Fi” (Mobile TV On) is enabled on the TV.")
        }
    }

    func powerOff() {
        send { try await $0.powerOff() }
    }

    /// When the app last turned the TV on (see `pressPower()`).
    @ObservationIgnored private var poweredOnAt: ContinuousClock.Instant?
    @ObservationIgnored private var powerOffArmedUntil: ContinuousClock.Instant?

    enum PowerPress { case turningOn, alreadyTurningOn, confirmOff, turnedOff }

    /// The remote's power key. Waking a TV takes a while (≈20 s on a 2019 set) with no visible change, so people press again: presses while
    /// waking are ignored, and for 15 s after the app turned the TV on a single press only arms "press again to turn off".
    func pressPower() -> PowerPress {
        let now = ContinuousClock.now
        if isWaking { return .alreadyTurningOn }
        guard isConnected else {
            Task {
                await powerOn()
                if isConnected { poweredOnAt = .now }
            }
            return .turningOn
        }
        if let on = poweredOnAt, now - on < .seconds(15), !(powerOffArmedUntil.map { now < $0 } ?? false) {
            powerOffArmedUntil = now + .seconds(4)
            return .confirmOff
        }
        powerOffArmedUntil = nil; poweredOnAt = nil
        powerOff()
        return .turnedOff
    }

    // MARK: - Saved TVs

    func remember(_ device: TVDevice) {
        if device.isDemo || device.id == TVDevice.demo.id { return }
        store.setLastUsedDeviceID(device.id)
        hasSetup = true
        if current?.id == device.id { current = device }
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device } else { devices.append(device) }
        store.saveDevices(devices)
    }

    func rename(_ device: TVDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[i].name = trimmed
        store.saveDevices(devices)
        if current?.id == device.id { current?.name = trimmed }
    }

    func forget(_ device: TVDevice) async {
        if current?.id == device.id { await disconnect() }
        devices.removeAll { $0.id == device.id }
        keys.setClientKey(nil, for: device.id)
        store.saveDevices(devices)
        if store.lastUsedDeviceID() == device.id {
            store.setLastUsedDeviceID(devices.first?.id)
            hasSetup = !devices.isEmpty
        }
    }

    /// Clears every saved TV and pairing key (`-resetOnboarding`).
    func resetAll() {
        for d in devices { keys.setClientKey(nil, for: d.id) }
        devices = []
        store.saveDevices([])
        store.setLastUsedDeviceID(nil)
        hasSetup = false
        current = nil
    }

    // MARK: - Discovery

    /// Streams TVs into `discovered`. Saved TVs found at a new IP are updated in place.
    func startDiscovery(timeout: TimeInterval = 8) {
        discoveryTask?.cancel()
        discovered = []
        isDiscovering = true
        discoveryTask = Task { [weak self] in
            guard let stream = self?.discovery.discover(timeout: timeout) else { return }
            for await found in stream {
                guard let self, !Task.isCancelled else { return }
                self.absorb(found)
            }
            self?.isDiscovering = false
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel(); discoveryTask = nil
        isDiscovering = false
    }

    /// Asks a typed-in address whether it is a webOS TV.
    func probe(host: String) async -> TVDevice? {
        let found = await discovery.probe(host: host)
        if let found { absorb(found) }
        return found
    }

    /// Merges a discovered TV into the live list and refreshes the saved copy's address.
    private func absorb(_ found: TVDevice) {
        if let i = discovered.firstIndex(where: { $0.id == found.id }) { discovered[i] = found } else { discovered.append(found) }
        guard let i = TVDeviceMerge.indexOfMatch(for: found, in: devices) else { return }
        let saved = devices[i]
        let updated = TVDeviceMerge.updated(saved, with: found)
        guard updated != saved else { return }
        devices[i] = updated
        store.saveDevices(devices)
        if current?.id == saved.id {
            current = updated
            if saved.host != updated.host, !isConnected, !isConnecting { reconnect() }
        }
    }

    static func isSameTV(_ a: TVDevice, _ b: TVDevice) -> Bool { TVDeviceMerge.isSameTV(a, b) }

    /// Short discovery looking for `device` at a different address.
    private func locateMoved(_ device: TVDevice) async -> TVDevice? {
        for await found in discovery.discover(timeout: 4) where Self.isSameTV(device, found) {
            guard found.host != device.host else { return nil }
            return TVDeviceMerge.updated(device, with: found)
        }
        return nil
    }

    // MARK: - Commands

    /// Fire-and-forget command. Errors land in `lastError`.
    /// If the TV isn't connected, starts a reconnect and waits briefly for it before giving up.
    /// While disconnected only the first command waits; later ones are dropped, so a held volume key doesn't
    /// pile up presses that all fire after the user has let go.
    func send(_ op: @escaping @Sendable (any TVControlling) async throws -> Void) {
        let waits = !(isConnected && tv != nil)
        if waits {
            guard sendsAwaitingConnection == 0 else { return }
            sendsAwaitingConnection += 1
        }
        Task {
            let ready = await readyClient()
            if waits { sendsAwaitingConnection -= 1 }
            guard let tv = ready else { return }
            do { try await op(tv); self.lastError = nil }
            catch { self.report(error) }
        }
    }

    /// Awaitable command for callers that need the result.
    func run<T: Sendable>(_ op: @Sendable (any TVControlling) async throws -> T) async throws -> T {
        guard let tv = await readyClient(silent: true) else { throw LGError.notConnected }
        return try await op(tv)
    }

    private func readyClient(silent: Bool = false) async -> (any TVControlling)? {
        if isConnected, let tv { return tv }
        guard let device = current else {
            if !silent { report(LGError.notConnected) }
            return nil
        }
        if !isConnecting, !isWaking, pairingRequest == nil, state != .connecting {
            if case .reconnecting = state {} else { reconnect() }
        }
        let start = ContinuousClock.now
        while !isConnected, ContinuousClock.now - start < .seconds(4), current?.id == device.id {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isConnected, let tv { return tv }
        if !silent {
            report(message: appearsOff ? "\(device.name) is off. Press the power key to turn it on."
                                       : "Can't reach \(device.name) right now.")
        }
        return nil
    }

    func report(_ error: Error) {
        if let e = error as? LGError, e == .notConnected, current != nil { reconnect() }
        report(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    func report(message: String) {
        lastError = message
        Haptics.error()
    }
}

/// A saved TV that didn't answer on its SSAP ports (off, unplugged, or on another network).
private struct UnreachableTV: LocalizedError {
    let name: String
    var errorDescription: String? { "Can't reach \(name). Make sure it's on and connected to the same Wi-Fi." }
}
