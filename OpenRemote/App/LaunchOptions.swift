import Foundation
import LGKit

/// Launch arguments used by UI tests and the App Store screenshot script. Keep these names stable.
///   -demo                   Debug simulator only: skip setup and connect to a simulated TV
///   -mode <remote|apps|inputs>   (old values: touchpad and the removed styles open Remote, media opens Remote)
///   -sheet <keyboard|voice|cast|settings|picker|addtv>   (tvs and sleep open Settings)
///   -resetOnboarding        clear saved TVs and preferences (setup starts again)
///   -pairing <accept|pin>   (debug) show the pairing screen
struct LaunchOptions {
    var demo = false
    var resetOnboarding = false
    var mode: RemoteMode?
    var sheet: MainSheet?
    var pairing: String?

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1].lowercased()
        }
        #if DEBUG && targetEnvironment(simulator)
        demo = arguments.contains("-demo")
        #endif
        resetOnboarding = arguments.contains("-resetOnboarding")
        switch value(after: "-mode") {
        case "remote", "touchpad", "classic", "swipe", "numpad", "numbers", "extras", "airmouse", "media": mode = .remote
        case "apps": mode = .apps
        case "inputs": mode = .inputs
        default: break
        }
        switch value(after: "-sheet") {
        case "keyboard": sheet = .keyboard
        case "voice": sheet = .voice
        case "cast": sheet = .cast
        case "inputpicker": sheet = .inputs
        case "settings", "tvs", "sleep": sheet = .settings
        case "picker", "remote", "remotepicker": sheet = .remotePicker
        case "addtv", "add": sheet = .addTV
        default: break
        }
        pairing = value(after: "-pairing")
    }

    /// Applies the launch arguments before the first frame renders.
    @MainActor
    func apply(to session: TVSession) {
        let defaults = UserDefaults.standard
        if resetOnboarding {
            let appSlots = (0..<4).map { "remote.appSlot.\($0)" }  // pre-v2 builds' key assignments
            for key in [PrefKey.haptics, PrefKey.keepAwake, PrefKey.remoteChosen, PrefKey.selectedRemote, PrefKey.lastMode,
                        AppOrder.key, AppOrder.legacyFavoritesKey, PrefKey.favoriteApps] + appSlots {
                defaults.removeObject(forKey: key)
            }
            session.resetAll()
        }
        if let mode { defaults.set(mode.rawValue, forKey: PrefKey.lastMode) }
        #if DEBUG && targetEnvironment(simulator)
        if demo { session.startDemo() } else { session.resume() }
        #else
        session.resume()
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-wakeLog") {
            let t0 = Date()
            let log: @Sendable (String) -> Void = { print(String(format: "[%6.2fs] ", Date().timeIntervalSince(t0)) + $0) }
            setvbuf(stdout, nil, _IOLBF, 0)
            WakeOnLAN.log = log
            TVClientFactory.log = log
            session.diagnostics = log
            // Watchdog: report when the main thread stops responding for more than a second.
            Thread.detachNewThread {
                while true {
                    let ping = DispatchSemaphore(value: 0), sent = Date()
                    DispatchQueue.main.async { ping.signal() }
                    if ping.wait(timeout: .now() + 1) == .timedOut {
                        ping.wait()
                        log("MAIN THREAD BLOCKED for \(String(format: "%.1f", Date().timeIntervalSince(sent)))s")
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-powerOnTest") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                session.diagnostics?("powerOnTest: current=\(session.current?.name ?? "nil") host=\(session.current?.host ?? "nil") macs=\(session.current?.macAddresses ?? []) state=\(session.state)")
                await session.powerOn()
                session.diagnostics?("powerOnTest: done connected=\(session.isConnected) state=\(session.state) error=\(session.lastError ?? "nil")")
            }
        }
        #endif
    }
}
