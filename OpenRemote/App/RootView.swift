import SwiftUI
import LGKit

/// First launch runs the 3-step setup — (1) pick your TV, (2) pair (sheet), (3) "Select a remote" — then shows
/// the main screen. Also owns app-wide presentation: the pairing prompt and the keep-awake preference.
struct RootView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PrefKey.keepAwake) private var keepAwake = false
    @AppStorage(PrefKey.remoteChosen) private var remoteChosen = false
    @AppStorage(PrefKey.lastMode) private var lastMode = RemoteMode.remote.rawValue
    /// `-pairing accept|pin` (debug / screenshots) shows the pairing screen without a TV.
    @State private var debugPairing: PairingRequest? = Self.launchPairing()

    private enum Phase { case pickTV, pickRemote, main }

    private var phase: Phase {
        guard session.hasSetup, session.current != nil else { return .pickTV }
        // `-demo` (screenshots, UI tests) skips the whole setup, including the remote picker.
        if !remoteChosen && !LaunchOptions.current.demo { return .pickRemote }
        return .main
    }

    var body: some View {
        ZStack {
            switch phase {
            case .main:
                MainView()
                    .transition(.opacity)
            case .pickRemote:
                RemotePickerView(tvModelYear: TVModelYear.year(for: session.current)) {
                    lastMode = RemoteMode.remote.rawValue
                    remoteChosen = true
                }
                .errorBanner()
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .pickTV:
                NavigationStack {
                    ConnectView(context: .onboarding)
                }
                .errorBanner()
                .transition(.opacity)
            }
        }
        .animation(Theme.smooth, value: phase)
        .tint(Theme.accent)
        .sheet(isPresented: pairingPresented) {
            PairingView(request: debugPairing ?? session.pairingRequest ?? .acceptOnTV) {
                debugPairing = nil
                session.cancelPairing()
            }
        }
        .onChange(of: keepAwake, initial: true) { updateIdleTimer() }
        .onChange(of: scenePhase) { updateIdleTimer() }
    }

    private var pairingPresented: Binding<Bool> {
        Binding(
            get: { debugPairing != nil || session.pairingRequest != nil },
            set: { shown in
                guard !shown else { return }
                debugPairing = nil
                session.cancelPairing()
            })
    }

    private static func launchPairing() -> PairingRequest? {
        switch LaunchOptions.current.pairing {
        case "accept": .acceptOnTV
        case "pin": .enterPIN
        default: nil
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && scenePhase == .active
    }
}

#Preview("Remote") {
    RootView().environment(TVSession.preview())
}

#Preview("Setup") {
    RootView().environment(TVSession.preview(connected: false))
}
