import SwiftUI
import LGKit

/// One big trackpad driving the TV's pointer (tap = click, drag = move, two fingers = scroll, two-finger tap = Back)
/// with only Back and Home below. Gesture tips show until the pad is first used.
/// Contract: `TouchpadView()` takes no arguments and reads `@Environment(TVSession.self)`.
struct TouchpadView: View {
    @Environment(TVSession.self) private var session
    @AppStorage(InputSettingsKey.touchpadSensitivity) private var sensitivity = 1.0
    @AppStorage(InputSettingsKey.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(InputSettingsKey.naturalScrolling) private var naturalScrolling = true
    @AppStorage(InputSettingsKey.touchpadTipsSeen) private var tipsSeen = false
    @State private var model = TouchpadModel()

    private let corner: CGFloat = 28

    var body: some View {
        VStack(spacing: Theme.spacing) {
            pad
            HStack(spacing: 14) {
                key("Back", "arrow.uturn.backward", .back)
                key("Home", "house", .home)
            }
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.bottom, Theme.spacing)
        .padding(.top, 4)
        .onAppear { model.sender.session = session }
        .onDisappear { model.stop() }
    }

    private var pad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.padBackground)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)

            padCenter
                .allowsHitTesting(false)

            TouchSurface { action in
                if !tipsSeen, action.marksTipsSeen { tipsSeen = true }
                model.handle(action, settings: .init(sensitivity: sensitivity, scrollSpeed: scrollSpeed, natural: naturalScrolling)) {
                    session.send { try await $0.press(.back) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            HStack {
                Spacer()
                if model.isScrolling { ScrollIndicator() }
            }
            .padding(.trailing, 10)
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.18), value: model.isScrolling)
        .animation(.easeOut(duration: 0.25), value: tipsSeen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touchpad")
        .accessibilityHint("Slide one finger to move the TV pointer. Tap to click. Use two fingers to scroll.")
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: "Click") { model.sender.click() }
        .accessibilityAction(named: "Back") { session.send { try await $0.press(.back) } }
        .accessibilityAction(named: "Scroll up") { model.sender.scroll(PointerDelta(dx: 0, dy: -60)) }
        .accessibilityAction(named: "Scroll down") { model.sender.scroll(PointerDelta(dx: 0, dy: 60)) }
    }

    @ViewBuilder private var padCenter: some View {
        if !session.isConnected {
            Label("Not connected to a TV", systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if !tipsSeen {
            GestureTips().transition(.opacity)
        }
    }

    private func key(_ title: LocalizedStringKey, _ symbol: String, _ remoteKey: RemoteKey) -> some View {
        Button {
            Haptics.tap()
            session.send { try await $0.press(remoteKey) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Theme.smallButtonSize)
                .background(Theme.buttonBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .foregroundStyle(.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(InputPressStyle())
    }
}

private extension TouchpadAction {
    /// The first real gesture on the pad retires the tips.
    var marksTipsSeen: Bool {
        switch self {
        case .click, .twoFingerTap, .dragEnded, .scrollEnded: true
        case .move: true
        default: false
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class TouchpadModel {
    struct Settings { var sensitivity: Double; var scrollSpeed: Double; var natural: Bool }

    private(set) var isDragging = false
    private(set) var isScrolling = false

    @ObservationIgnored let sender = PointerSender()
    @ObservationIgnored private var accelerator = PointerAccelerator()
    @ObservationIgnored private var scrollCarry = RemainderCarry()

    /// webOS scrolls in small steps; finger points are scaled down so a short swipe scrolls a few rows.
    private let scrollGain = 0.5

    func handle(_ action: TouchpadAction, settings: Settings, back: () -> Void) {
        switch action {
        case let .move(d, dt, drag):
            accelerator.sensitivity = settings.sensitivity
            sender.move(accelerator.process(d, dt: dt), drag: drag)
        case let .scroll(d):
            // webOS: positive dy scrolls content down (like a mouse wheel). Natural scrolling follows the fingers.
            let sign = settings.natural ? -1.0 : 1.0
            let k = scrollGain * settings.scrollSpeed * sign
            sender.scroll(scrollCarry.take(PointerDelta(dx: d.dx * k, dy: d.dy * k)))
        case .click:
            Haptics.press()
            sender.click()
        case .twoFingerTap:
            Haptics.tap()
            back()
        case .dragBegan:
            Haptics.press()
            isDragging = true
        case .dragEnded:
            isDragging = false
            accelerator.reset()
            sender.endDrag()
        case .scrollBegan:
            isScrolling = true
        case .scrollEnded:
            isScrolling = false
            scrollCarry.reset()
        }
    }

    func stop() {
        if isDragging { sender.endDrag() }
        isDragging = false
        isScrolling = false
        sender.cancelPending()
    }
}

// MARK: - Pieces

private struct ScrollIndicator: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.up")
            Capsule().frame(width: 4, height: 54)
            Image(systemName: "chevron.down")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(Theme.accent)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.thinMaterial, in: Capsule())
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

/// First-use gesture tips in the middle of the pad.
private struct GestureTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            item("hand.tap", "Tap to click")
            item("hand.point.up.left", "Slide to move the pointer")
            item("hand.draw", "Touch and hold, then slide to drag")
            item("arrow.up.and.down", "Two fingers to scroll")
            item("arrow.uturn.backward", "Two-finger tap for Back")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(24)
        .accessibilityHidden(true)
    }

    private func item(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 28)
        }
    }
}

/// Sheet explaining every touchpad gesture.
struct TouchpadGestureGuide: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String, String)] = [
        ("hand.point.up.left", "Move", "Slide one finger. Move faster to cross the screen, slower for precision."),
        ("hand.tap", "Click", "Tap once anywhere on the pad."),
        ("hand.draw", "Drag", "Touch and hold until you feel a tap, then slide. Lift to drop."),
        ("arrow.up.and.down", "Scroll", "Slide two fingers up, down or sideways."),
        ("arrow.uturn.backward", "Back", "Tap with two fingers at once."),
    ]

    var body: some View {
        NavigationStack {
            List(rows, id: \.1) { row in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: row.0)
                        .font(.title3)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.1).font(.headline)
                        Text(row.2).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .navigationTitle("Touchpad Gestures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    TouchpadView().environment(TVSession.preview())
}
