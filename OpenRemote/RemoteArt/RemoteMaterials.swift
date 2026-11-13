import SwiftUI
import LGKit

// What the keys on a remote picture do, and the controller that runs them.

// MARK: - Actions

/// What a key on a remote picture does.
enum RemoteAction: Hashable {
    case key(RemoteKey)
    case volumeUp, volumeDown, channelUp, channelDown
    case power, voice, inputs
    /// A brand key printed on the remote (Netflix, Prime Video, …): opens the TV app whose id or title matches.
    case launch(app: String)
    /// A key with no network command; tapping explains instead of failing silently.
    case unsupported(String)
}

extension RemoteAction {
    /// Display names for brand-key matches, used in messages ("Prime Video isn't installed on this TV").
    static func appName(_ match: String) -> String {
        [
            "netflix": "Netflix", "amazon": "Prime Video", "primevideo": "Prime Video", "disney": "Disney+",
            "youtube": "YouTube", "movies": "Movies", "rakuten": "Rakuten TV", "apple": "Apple TV",
            "spotify": "Spotify", "lgchannels": "LG Channels",
        ][match.lowercased()] ?? match.capitalized
    }
}

/// Executes remote actions against the session and owns the little bits of state the remote needs (toast, the TV's
/// app list for brand keys).
@MainActor
@Observable
final class RemoteController {
    let session: TVSession
    var toast: String?
    private(set) var apps: [TVApp] = []
    /// Gets first look at every action (phone-pointer mode turns OK into a click); return true to consume it.
    @ObservationIgnored var intercept: ((RemoteAction) -> Bool)?
    /// Opens the Voice sheet; set by the shell through `\.remoteVoiceAction`. Without it the key explains itself.
    @ObservationIgnored var voiceAction: (() -> Void)?
    /// Opens the Inputs sheet; set by the shell through `\.remoteInputsAction`. Without it the key opens the TV's
    /// own input list.
    @ObservationIgnored var inputsAction: (() -> Void)?

    init(session: TVSession) { self.session = session }

    func perform(_ action: RemoteAction) {
        session.diagnostics?("key \(action) connected=\(session.isConnected) state=\(session.state) waking=\(session.isWaking)")
        if let intercept, intercept(action) { return }
        switch action {
        case .key(let k): session.send { try await $0.press(k) }
        case .volumeUp: session.send { try await $0.volumeUp() }
        case .volumeDown: session.send { try await $0.volumeDown() }
        case .channelUp: session.send { try await $0.channelUp() }
        case .channelDown: session.send { try await $0.channelDown() }
        case .power:
            switch session.pressPower() {
            case .turningOn, .turnedOff: break  // the remote tab shows a "Turning on…" banner while waking
            case .alreadyTurningOn: showToast(String(localized: "Still turning on. Give the TV a moment."))
            case .confirmOff: showToast(String(localized: "The TV just turned on. Press power again to turn it off."))
            }
        case .voice:
            if let voiceAction { voiceAction() } else { showToast(String(localized: "Use the microphone at the top to talk to your TV")) }
        case .inputs:
            if let inputsAction { inputsAction() } else { session.send { try await $0.press(.inputHub) } }
        case .launch(let match):
            Task { await launch(match) }
        case .unsupported(let name):
            showToast(String(localized: "\(name) isn't available over Wi‑Fi"))
        }
    }

    private func launch(_ match: String) async {
        if apps.isEmpty { await loadApps() }
        guard session.isConnected else {
            session.send { _ in }  // says "TV is off" / reconnects, like any other key
            return
        }
        let m = match.lowercased()
        if let app = apps.first(where: {
            $0.id.lowercased().contains(m) || $0.title.lowercased().replacingOccurrences(of: " ", with: "").contains(m)
        }) {
            session.send { try await $0.launchApp(id: app.id, params: nil) }
        } else {
            showToast(String(localized: "\(RemoteAction.appName(match)) isn't installed on this TV"))
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if toast == text { toast = nil }
        }
    }

    func loadApps() async {
        guard session.isConnected, let list = try? await session.run({ try await $0.apps() }) else { return }
        apps = list
    }
}
