#if DEBUG
import SwiftUI
import LGKit

/// Debug launch arguments to look at the Remote tab pieces before the shell uses them (combine with `-demo`):
///   -remoteTab              the Remote tab, phone layout
///   -remoteTabPad           the Remote tab, iPad side-by-side layout
///   -remotePicker           "Select a remote", then the Remote tab
///   -remoteSample           (old name) same as -remoteTab
enum RemoteArtDebug {
    @MainActor
    static func view(session: TVSession, arguments: [String] = ProcessInfo.processInfo.arguments) -> AnyView? {
        if arguments.contains("-remotePicker") { return AnyView(PickerThenRemote()) }
        if arguments.contains("-remoteTabPad") { return AnyView(DebugRemoteTab(layout: .sideBySide)) }
        if arguments.contains("-remoteTab") || arguments.contains("-remoteSample") { return AnyView(DebugRemoteTab(layout: .phone)) }
        return nil
    }
}

/// Stand-in for the shell's top row so screenshots look close to the real tab.
private struct DebugRemoteTab: View {
    let layout: RemoteTabLayout
    @Environment(TVSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.current?.name ?? "No TV").font(.headline)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                ForEach(["keyboard", "mic", "rectangle.on.rectangle"], id: \.self) {
                    Image(systemName: $0).font(.title3).frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            RemoteTabView(layout: layout)
        }
        .background(SoftBackground().ignoresSafeArea())
    }
}

private struct PickerThenRemote: View {
    @State private var done = false
    var body: some View {
        if done {
            DebugRemoteTab(layout: .phone)
        } else {
            RemotePickerView(tvModelYear: nil) { done = true }
        }
    }
}
#endif
