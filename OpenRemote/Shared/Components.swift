import SwiftUI
import LGKit

// Reusable remote building blocks. Feature agents may use these for a consistent look.

enum KeyShape {
    case circle, rounded, capsule, plain
}

/// The visual of a key: a raised cap that sinks slightly while pressed.
struct KeyCap<Label: View>: View {
    var shape: KeyShape = .circle
    var pressed: Bool
    var tint: Color? = nil
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(tint == nil ? Theme.keyForeground : Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { background }
            .contentShape(contentShape)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(Theme.press, value: pressed)
    }

    private var fill: Color {
        if let tint { return pressed ? tint.opacity(0.75) : tint }
        return pressed ? Theme.buttonPressed : Theme.buttonBackground
    }

    @ViewBuilder private var background: some View {
        switch shape {
        case .circle: Circle().fill(fill).overlay(Circle().strokeBorder(Theme.stroke)).keyShadow()
        case .rounded: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).strokeBorder(Theme.stroke)).keyShadow()
        case .capsule: Capsule().fill(fill).overlay(Capsule().strokeBorder(Theme.stroke)).keyShadow()
        case .plain: Rectangle().fill(pressed ? Theme.buttonPressed.opacity(0.6) : .clear)
        }
    }

    private var contentShape: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
        case .plain: AnyShape(Rectangle())
        }
    }
}

extension View {
    /// Soft drop shadow that only shows in light mode (dark mode relies on the hairline stroke).
    func keyShadow() -> some View { modifier(KeyShadow()) }

    /// Large raised surface (pads, cards).
    func surface(cornerRadius: CGFloat = Theme.corner) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.padBackground)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
                .keyShadow()
        }
    }
}

private struct KeyShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(scheme == .dark ? 0 : 0.07), radius: 6, y: 2)
    }
}

/// Standard key style: haptic on touch-down, action on release.
struct KeyStyle: ButtonStyle {
    var shape: KeyShape = .circle
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        KeyCap(shape: shape, pressed: configuration.isPressed, tint: tint) { configuration.label }
            .onChange(of: configuration.isPressed) { _, down in if down { Haptics.tap() } }
    }
}

/// Small round icon button used in toolbars / top bar.
struct CircleIconButton: View {
    let symbol: String
    let title: String
    var tint: Color? = nil
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(KeyStyle(shape: .circle, tint: tint))
        .frame(width: size, height: size)
        .accessibilityLabel(title)
    }
}

/// Section caption used above groups of keys.
struct SectionCaption: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).tracking(1)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
