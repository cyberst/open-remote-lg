import SwiftUI
import LGKit

@main
struct OpenRemoteApp: App {
    @State private var session: TVSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = TVSession.live()
        LaunchOptions.current.apply(to: session)
        _session = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let debugView = RemoteArtDebug.view(session: session) {
                    debugView
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(session)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: session.resume()
            case .background: session.suspend()
            default: break
            }
        }
    }
}
