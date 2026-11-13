import SwiftUI
import LGKit

/// How the Remote tab is arranged.
enum RemoteTabLayout {
    /// iPhone: Remote · Touchpad switcher at the top, one of them below.
    case phone
    /// iPad: the remote on the left and the touchpad permanently on the right; no switcher.
    case sideBySide
}

/// Lets the shell open its Voice sheet when the remote's microphone key is pressed:
/// `RemoteTabView().environment(\.remoteVoiceAction) { sheet = .voice }`.
struct RemoteVoiceActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

/// Lets the shell open its Inputs sheet when the remote's input key is pressed.
struct RemoteInputsActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var remoteVoiceAction: (@MainActor () -> Void)? {
        get { self[RemoteVoiceActionKey.self] }
        set { self[RemoteVoiceActionKey.self] = newValue }
    }
    var remoteInputsAction: (@MainActor () -> Void)? {
        get { self[RemoteInputsActionKey.self] }
        set { self[RemoteInputsActionKey.self] = newValue }
    }
}

/// The whole Remote tab below the shell's top row: the chosen remote picture (with the phone-pointer switch) and
/// the touchpad. Reads `@Environment(TVSession.self)`; the chosen remote is `UserDefaults "remote.selectedID"`.
struct RemoteTabView: View {
    enum Surface: String, CaseIterable { case remote, touchpad }

    let layout: RemoteTabLayout
    @Environment(TVSession.self) private var session
    @State private var surface: Surface = .remote
    @State private var controller: RemoteController?
    /// Lives as long as the tab, so the switch survives Remote ⇄ Touchpad; off again at every launch.
    @State private var pointer = PhonePointer()

    init(layout: RemoteTabLayout = .phone) { self.layout = layout }

    var body: some View {
        Group {
            switch layout {
            case .phone: phone
            case .sideBySide: sideBySide
            }
        }
        .background(SoftBackground().ignoresSafeArea())
        .onAppear {
            if controller == nil { controller = RemoteController(session: session) }
            pointer.attach(session)
        }
    }

    @ViewBuilder private var remotePane: some View {
        if let controller {
            RemotePane(widthFraction: 0.74, maxRemoteWidth: 340, controller: controller, pointer: pointer)
        } else {
            Color.clear
        }
    }

    private var phone: some View {
        VStack(spacing: 0) {
            Picker("Control", selection: $surface) {
                Text("Remote").tag(Surface.remote)
                Text("Touchpad").tag(Surface.touchpad)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.spacing)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .onChange(of: surface) { _, _ in Haptics.tick() }

            switch surface {
            case .remote: remotePane
            case .touchpad: TouchpadView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sideBySide: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                remotePane
                    .frame(width: min(max(geo.size.width * 0.42, 320), 480))
                TouchpadView()
                    .padding(.top, Theme.spacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Remote pane

/// The chosen remote, scrolling vertically when taller than the screen, with the phone-pointer switch in a corner.
private struct RemotePane: View {
    let widthFraction: CGFloat
    let maxRemoteWidth: CGFloat

    @Environment(TVSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.remoteVoiceAction) private var voiceAction
    @Environment(\.remoteInputsAction) private var inputsAction
    @AppStorage(RemoteCatalog.selectedIDKey) private var selectedID: String?
    @AppStorage(InputSettingsKey.airMouseSensitivity) private var airSensitivity = 1.0
    let controller: RemoteController
    let pointer: PhonePointer

    private var spec: RemoteSpec? {
        RemoteCatalog.shared.remote(id: selectedID) ?? RemoteCatalog.shared.selected
    }

    var body: some View {
        GeometryReader { geo in
            if let spec {
                let width = min(geo.size.width * widthFraction, maxRemoteWidth)
                ScrollView(.vertical) {
                    RemoteCanvas(spec: spec, width: width)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                        .padding(.bottom, 48)
                }
                .scrollIndicators(.hidden)
                .id(spec.id) // a newly chosen remote opens at its top
                .environment(controller)
                .overlay(alignment: .topTrailing) {
                    if pointer.isAvailable {
                        PointerSwitch(isOn: Bindable(pointer).isOn).padding(.trailing, 6).padding(.top, 6)
                    }
                }
                // Notes sit at the top: the floating tab bar covers the bottom of the screen.
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if session.isWaking { wakingBanner }
                        toast(controller.toast)
                    }
                    .padding(.top, 8)
                }
                .animation(.easeOut(duration: 0.2), value: controller.toast)
                .animation(.easeOut(duration: 0.2), value: session.isWaking)
                .task(id: session.observationKey) { await controller.loadApps() }
            } else {
                ContentUnavailableView("No remotes", systemImage: "appletvremote.gen4")
            }
        }
        .onAppear {
            controller.voiceAction = voiceAction
            controller.inputsAction = inputsAction
            controller.intercept = { [pointer] action in pointer.intercept(action) }
            pointer.isVisible = true
            update()
        }
        .onDisappear {
            pointer.isVisible = false
            update()
        }
        .onChange(of: pointer.isOn) { _, on in
            Haptics.tick()
            if on { controller.showToast(String(localized: "Point at the TV. OK clicks.")) }
            update()
        }
        .onChange(of: scenePhase) { _, _ in update() }
        .onChange(of: airSensitivity) { _, _ in update() }
    }

    private func update() {
        pointer.update(active: scenePhase == .active, sensitivity: airSensitivity)
    }

    @ViewBuilder private func toast(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Shown while the TV is being woken (it can take a while): without it the remote looks unresponsive and people press again.
    private var wakingBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Turning on \(session.current?.name ?? String(localized: "your TV"))…")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("The TV may take a moment to start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Phone pointer (Air Mouse)

/// Phone pointing: while on, moving the phone moves the TV pointer, OK clicks where it points, and an arrow key
/// hides the pointer until the phone moves again. Off at every launch (never persisted). The motion sensor runs
/// only while on, the remote is on screen and the app is active.
@MainActor
@Observable
final class PhonePointer {
    var isOn = false
    @ObservationIgnored var isVisible = false
    @ObservationIgnored private let air = AirMouseController()

    var isAvailable: Bool { air.isAvailable }

    func attach(_ session: TVSession) { air.sender.session = session }

    func update(active: Bool, sensitivity: Double) {
        if isOn && isVisible && active {
            air.start(sensitivity: sensitivity)
        } else {
            air.stop()
            air.sender.cancelPending()
        }
    }

    /// Remote keys pass through here first while pointing is on.
    func intercept(_ action: RemoteAction) -> Bool {
        guard isOn else { return false }
        switch action {
        case .key(.enter):
            air.sender.click()
            return true
        case .key(.up), .key(.down), .key(.left), .key(.right):
            air.holdUntilMotion()
            return false
        default:
            return false
        }
    }
}

/// A compact phone-and-cursor control. The movement arrow explains that moving the phone
/// steers the pointer; a solid accent and the label make the enabled state explicit.
private struct PointerSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 4) {
                PointerGlyph()
                Text(isOn ? "Pointing" : "Point")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.vertical, 8)
            .frame(width: 56)
            .background {
                if isOn {
                    shape.fill(Theme.accent)
                } else {
                    shape.fill(.regularMaterial)
                        .overlay(shape.strokeBorder(Theme.stroke))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(PointerSwitchStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOn)
        .accessibilityRepresentation {
            Toggle("Point with phone", isOn: $isOn)
                .accessibilityHint("Move your phone to move the TV pointer. OK clicks.")
        }
    }
}

private struct PointerSwitchStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A readable phone silhouette, an emerging cursor, and a sideways movement cue.
/// Static geometry keeps the action legible at the button's actual size.
private struct PointerGlyph: View {
    var body: some View {
        ZStack {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 26, weight: .medium))
                .rotationEffect(.degrees(-12))
                .position(x: 14, y: 15)
            Image(systemName: "cursorarrow")
                .font(.system(size: 17, weight: .semibold))
                .position(x: 33, y: 12)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .position(x: 24, y: 33)
        }
        .frame(width: 44, height: 38)
        .accessibilityHidden(true)
    }
}
