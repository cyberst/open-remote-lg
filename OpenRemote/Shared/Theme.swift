import SwiftUI
import UIKit

/// Shared design tokens. Owned by the App Shell agent; other feature agents should use these, not hard-coded values.
/// Direction: calm, native, dark-first. Large tap targets (>= 56pt), SF Symbols only, system materials, haptics on every press.
enum Theme {
    // MARK: Colour
    static let accent = Color.accentColor
    /// Screen background: near-black in dark mode, soft grey in light mode so key surfaces read as raised.
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.035, alpha: 1) : UIColor(red: 0.945, green: 0.949, blue: 0.961, alpha: 1) })
    /// Large interactive surfaces (touchpad, swipe pad, D-pad ring).
    static let padBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.11, alpha: 1) : UIColor.white })
    /// Key caps.
    static let buttonBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.16, alpha: 1) : UIColor.white })
    /// Key caps while pressed.
    static let buttonPressed = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.88, alpha: 1) })
    /// Hairline used to lift surfaces off the background.
    static let stroke = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.06) })
    static let keyForeground = Color.primary
    static let secondaryText = Color.secondary

    /// Colour keys use muted versions so they don't shout in a dark room.
    static let red = Color(red: 0.90, green: 0.30, blue: 0.30)
    static let green = Color(red: 0.30, green: 0.75, blue: 0.42)
    static let yellow = Color(red: 0.95, green: 0.78, blue: 0.25)
    static let blue = Color(red: 0.30, green: 0.52, blue: 0.95)

    static let connected = Color(red: 0.30, green: 0.80, blue: 0.45)
    static let warning = Color.orange
    static let offline = Color.secondary

    // MARK: Metrics
    static let buttonSize: CGFloat = 64
    static let smallButtonSize: CGFloat = 52
    static let corner: CGFloat = 20
    static let smallCorner: CGFloat = 14
    static let spacing: CGFloat = 16
    static let gutter: CGFloat = 20
    /// Max width of the remote column so iPad / landscape never shows a stretched phone layout.
    static let remoteMaxWidth: CGFloat = 420

    // MARK: Motion
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)
    static let smooth = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

/// User preference keys (shared so feature agents can read them too).
/// Note: keys deliberately avoid launch-argument names (`-mode`, `-sheet`, `-demo`), because UserDefaults
/// treats `-key value` launch arguments as a read-only override domain.
enum PrefKey {
    static let haptics = "pref.haptics"
    static let keepAwake = "pref.keepAwake"
    /// Set when the user picked a remote in "Select a remote" (last setup step). Until then the picker shows.
    static let remoteChosen = "pref.remoteChosen"
    static let lastMode = "pref.lastMode"
    /// v1 favourites; `AppOrder.saved` migrates them to the front of the app order.
    static let favoriteApps = "pref.favoriteApps"
    /// Agent A's remote selection (written by `RemotePickerView`); the shell only clears it on `-resetOnboarding`.
    static let selectedRemote = "remote.selectedID"
}

enum Haptics {
    private static var enabled: Bool { UserDefaults.standard.object(forKey: PrefKey.haptics) as? Bool ?? true }
    static func tap() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func press() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func tick() { guard enabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
