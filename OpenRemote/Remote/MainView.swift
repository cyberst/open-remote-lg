import SwiftUI
import LGKit

/// Lets nested controls open a main-screen sheet.
/// Read with `@Environment(SheetRouter.self) private var router: SheetRouter?`.
@MainActor
@Observable
final class SheetRouter {
    var sheet: MainSheet? = LaunchOptions.current.sheet
}

/// The main screen: the top row (TV ▾ menu, Keyboard, Voice, Cast) over three tabs — Remote · Apps · Inputs.
/// On iPad the Remote tab shows the remote on the left and the touchpad on the right.
struct MainView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(PrefKey.lastMode) private var modeRaw = RemoteMode.remote.rawValue
    @State private var router = SheetRouter()

    private var mode: Binding<RemoteMode> {
        Binding(get: { RemoteMode(rawValue: modeRaw) ?? .remote }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            // iPad: the tabs sit in the top row (iPadOS's floating tab bar would cover the tabs' own content).
            TopRow(sheet: $router.sheet, tabs: sizeClass == .regular ? mode : nil)
            if sizeClass == .regular {
                Group {
                    switch mode.wrappedValue {
                    case .remote: remoteTab
                    case .apps: AppsView()
                    case .inputs: InputsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: mode) {
                    tab(.remote) { remoteTab }
                    tab(.apps) { AppsView() }
                    tab(.inputs) { InputsView() }
                }
            }
        }
        // The Remote tab's soft backdrop continues behind the top row.
        .background { if mode.wrappedValue == .remote { SoftBackground().ignoresSafeArea() } else { Theme.background.ignoresSafeArea() } }
        .errorBanner()
        .environment(router)
        .sheet(item: $router.sheet) { MainSheetContent(sheet: $0) }
        // Casting follows the current TV (stops when the user switches TVs).
        .onChange(of: session.current?.id) { CastController.shared.tvChanged(to: $1) }
    }

    private var remoteTab: some View {
        RemoteTabView(layout: sizeClass == .regular ? .sideBySide : .phone)
            .environment(\.remoteVoiceAction) { router.sheet = .voice }
            .environment(\.remoteInputsAction) { router.sheet = .inputs }
    }

    private func tab<Content: View>(_ mode: RemoteMode, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // RemoteTabView draws its own soft backdrop; Apps and Inputs sit on the plain one.
            .background { if mode != .remote { Theme.background.ignoresSafeArea(edges: .bottom) } }
            .tabItem { Label(mode.title, systemImage: mode.symbol) }
            .tag(mode)
    }
}

// MARK: - Top row

/// TV name ▾ (switch TV, Add TV…, Change Remote…, Settings) with a quiet status line, then Keyboard, Voice, Cast.
/// No power button here: power is a key on the remote.
struct TopRow: View {
    @Binding var sheet: MainSheet?
    /// iPad only: the Remote · Apps · Inputs switcher, centred in the row.
    var tabs: Binding<RemoteMode>? = nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                TVMenu(sheet: $sheet)
                StatusLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let tabs {
                Picker("Tab", selection: Binding(get: { tabs.wrappedValue }, set: { Haptics.tick(); tabs.wrappedValue = $0 })) {
                    ForEach(RemoteMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            HStack(spacing: 10) {
                CircleIconButton(symbol: "keyboard", title: "Keyboard") { Haptics.tap(); sheet = .keyboard }
                CircleIconButton(symbol: "mic", title: "Voice command") { Haptics.tap(); sheet = .voice }
                CircleIconButton(symbol: "photo.tv", title: "Cast photos and videos") { Haptics.tap(); sheet = .cast }
            }
            .frame(maxWidth: tabs == nil ? nil : .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// The TV name as a native menu: saved TVs (checkmark on the current one), then Add TV…, Change Remote…, Settings.
struct TVMenu: View {
    @Environment(TVSession.self) private var session
    @Binding var sheet: MainSheet?

    private var tvs: [TVDevice] {
        #if DEBUG && targetEnvironment(simulator)
        if let current = session.current, current.isDemo { return session.devices + [current] }
        #endif
        return session.devices
    }

    var body: some View {
        Menu {
            Section {
                ForEach(tvs) { device in
                    Button { select(device) } label: {
                        if device.id == session.current?.id {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                    .accessibilityAddTraits(device.id == session.current?.id ? .isSelected : [])
                }
            }
            Section {
                Button { sheet = .addTV } label: { Label("Add TV…", systemImage: "plus") }
                Button { sheet = .remotePicker } label: { Label("Change Remote…", systemImage: "av.remote") }
                Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            }
        } label: {
            HStack(spacing: 5) {
                Text(session.current?.name ?? "No TV")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .tint(.primary)
        .accessibilityLabel("TV: \(session.current?.name ?? "none")")
        .accessibilityHint("Switch TV, add a TV, change the remote, or open Settings")
    }

    private func select(_ device: TVDevice) {
        Haptics.tap()
        if session.current?.id == device.id && (session.isConnected || session.isConnecting) { return }
        Task {
            // Let the menu finish closing so a pairing sheet can present cleanly.
            try? await Task.sleep(for: .milliseconds(250))
            await session.connect(to: device)
        }
    }
}

/// Quiet connection status under the TV name. Tap to retry when offline.
struct StatusLine: View {
    @Environment(TVSession.self) private var session

    private struct Status { var text: String; var color: Color; var busy: Bool; var retry: Bool }

    private var status: Status {
        if session.isWaking { return Status(text: "Turning on…", color: Theme.warning, busy: true, retry: false) }
        switch session.state {
        case .connected: return Status(text: "Connected", color: Theme.connected, busy: false, retry: false)
        case .pairing: return Status(text: "Waiting for TV…", color: Theme.warning, busy: true, retry: false)
        case .reconnecting: return Status(text: "Reconnecting…", color: Theme.warning, busy: true, retry: false)
        case .connecting: return Status(text: "Connecting…", color: Theme.warning, busy: true, retry: false)
        case .disconnected, .failed:
            if session.isConnecting { return Status(text: "Connecting…", color: Theme.warning, busy: true, retry: false) }
            if session.appearsOff { return Status(text: "TV is off · Tap to turn on", color: .secondary, busy: false, retry: true) }
            return Status(text: "Offline · Tap to retry", color: .secondary, busy: false, retry: true)
        }
    }

    var body: some View {
        let s = status
        Button {
            guard s.retry else { return }
            Haptics.tap()
            session.retryOrTurnOn()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(s.color)
                    .frame(width: 6, height: 6)
                    .opacity(s.busy ? 0.5 : 1)
                    .animation(s.busy ? .easeInOut(duration: 0.8).repeatForever() : .default, value: s.busy)
                Text(s.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!s.retry)
        .animation(Theme.smooth, value: s.text)
        .accessibilityLabel("Connection: \(s.text)")
        .accessibilityHint(s.retry ? (session.appearsOff ? "Double-tap to turn the TV on" : "Double-tap to reconnect") : "")
    }
}

// MARK: - Sheets

struct MainSheetContent: View {
    let sheet: MainSheet
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.remoteChosen) private var remoteChosen = false

    var body: some View {
        switch sheet {
        case .keyboard:
            KeyboardView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        case .voice:
            VoiceCommandView().presentationDetents([.fraction(0.72), .large]).presentationDragIndicator(.visible)
        case .cast:
            // CastSheet opens the photo picker itself and sets its own detents.
            CastSheet()
        case .inputs:
            // From the remote's input key: pick a source, and the sheet closes.
            NavigationStack {
                InputsView(onSelect: {
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))  // let the checkmark land
                        dismiss()
                    }
                })
                .navigationTitle("Inputs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .settings:
            NavigationStack { SettingsView() }
        case .addTV:
            NavigationStack {
                ConnectView(context: .add(onSelect: add))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    }
            }
        case .remotePicker:
            NavigationStack {
                // nil: opens on the current choice.
                RemotePickerView(tvModelYear: nil) {
                    remoteChosen = true
                    dismiss()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
    }

    /// Connects to a TV chosen in Add TV. The sheet closes first so the pairing prompt can be presented.
    private func add(_ device: TVDevice) {
        Haptics.tap()
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await session.connect(to: device)
        }
    }
}

// MARK: - Error banner

extension View {
    /// Shows `session.lastError` as a transient banner at the top.
    func errorBanner() -> some View { modifier(ErrorBannerModifier()) }
}

private struct ErrorBannerModifier: ViewModifier {
    @Environment(TVSession.self) private var session

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = session.lastError {
                Button { withAnimation(Theme.smooth) { session.lastError = nil } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text(message).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 520)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("Error: \(message)")
                .accessibilityHint("Double-tap to dismiss")
                .task(id: message) {
                    UIAccessibility.post(notification: .announcement, argument: message)
                    try? await Task.sleep(for: .seconds(4))
                    if session.lastError == message { withAnimation(Theme.smooth) { session.lastError = nil } }
                }
            }
        }
        .animation(Theme.smooth, value: session.lastError)
    }
}

#Preview("iPhone") {
    MainView().environment(TVSession.preview())
}
