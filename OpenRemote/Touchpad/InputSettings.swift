import SwiftUI

/// `@AppStorage` keys for pointer preferences (shared so a Settings screen can show the same controls).
enum InputSettingsKey {
    static let touchpadSensitivity = "input.touchpad.sensitivity"   // Double, 0.4…2.5, default 1
    static let scrollSpeed = "input.touchpad.scrollSpeed"           // Double, 0.4…2.5, default 1
    static let naturalScrolling = "input.touchpad.naturalScrolling" // Bool, default true
    static let airMouseSensitivity = "input.airMouse.sensitivity"   // Double, 0.4…2.5, default 1
    static let airMouseContinuous = "input.airMouse.continuous"     // Bool, default false
    static let touchpadTipsSeen = "input.touchpad.tipsSeen"         // Bool, default false
}

/// Pointer preferences as a form section. Embeddable in a Settings screen or shown as a sheet.
struct PointerSettingsSection: View {
    @AppStorage(InputSettingsKey.touchpadSensitivity) private var touchpadSensitivity = 1.0
    @AppStorage(InputSettingsKey.scrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(InputSettingsKey.naturalScrolling) private var naturalScrolling = true
    @AppStorage(InputSettingsKey.airMouseSensitivity) private var airMouseSensitivity = 1.0

    var body: some View {
        Section {
            SensitivitySlider(title: "Touchpad speed", value: $touchpadSensitivity)
            SensitivitySlider(title: "Scroll speed", value: $scrollSpeed)
            Toggle("Natural scrolling", isOn: $naturalScrolling)
            SensitivitySlider(title: "Air Mouse speed", value: $airMouseSensitivity)
        } header: {
            Text("Pointer")
        } footer: {
            Text("Natural scrolling moves the page with your fingers, like on iPhone.")
        }
    }
}

private struct SensitivitySlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack {
                Image(systemName: "tortoise").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $value, in: 0.4...2.5)
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
                Image(systemName: "hare").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }
}
