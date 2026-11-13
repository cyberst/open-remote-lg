import SwiftUI
import LGKit

/// One remote picture at a given width with transparent, shape-aware hit areas on top of its keys.
/// Pressing a key ticks the haptic and briefly brightens the key; app shortcut keys show the assigned TV app's icon.
struct RemoteCanvas: View {
    let spec: RemoteSpec
    let width: CGFloat
    @Environment(RemoteController.self) private var controller
    @Environment(\.displayScale) private var displayScale

    private var height: CGFloat { width / spec.aspectRatio }

    var body: some View {
        ZStack(alignment: .topLeading) {
            picture
            ForEach(spec.keys) { key in
                if let action = key.remoteAction, let r = key.unitRect {
                    let frame = CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height)
                    RemoteHitKey(key: key, action: action, size: frame.size)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder private var picture: some View {
        if let image = RemoteImageStore.image(for: spec, maxPixelHeight: Int((height * displayScale).rounded(.up))) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: height)
                // Real plastic casts a soft shadow on the backdrop.
                .shadow(color: .black.opacity(0.28), radius: 18, y: 14)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: width * 0.4, style: .continuous)
                .fill(Color(white: 0.1))
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        }
    }
}


extension RemoteKeySpec.Shape {
    /// Hit/glow shape for a key of the given size. Rect keys get softly rounded corners (they sit on moulded pieces).
    func shape(for size: CGSize) -> AnyShape {
        switch self {
        case .circle: AnyShape(Ellipse())
        case .capsule: AnyShape(Capsule())
        case .rect: AnyShape(RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.22, style: .continuous))
        }
    }
}

/// A transparent key over the picture.
private struct RemoteHitKey: View {
    let key: RemoteKeySpec
    let action: RemoteAction
    let size: CGSize
    @Environment(RemoteController.self) private var controller

    var body: some View {
        Button { controller.perform(action) } label: { Color.clear }
            .buttonStyle(GlowKeyStyle(shape: key.shape.shape(for: size)))
            .accessibilityLabel(key.label ?? action.spokenName)
    }
}

/// Transparent key: on press the key brightens (clipped to its shape) and fades out after release, so even a quick
/// tap shows; a light haptic ticks on touch-down.
struct GlowKeyStyle: ButtonStyle {
    var shape: AnyShape

    func makeBody(configuration: Configuration) -> some View {
        GlowKeyBody(configuration: configuration, shape: shape)
    }

    private struct GlowKeyBody: View {
        let configuration: Configuration
        let shape: AnyShape
        @State private var glow = 0.0

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    shape.fill(Color.white.opacity(0.42 * glow)).blendMode(.screen)
                }
                .overlay {
                    shape.stroke(Color.white.opacity(0.35 * glow), lineWidth: 1)
                }
                .contentShape(shape)
                .onChange(of: configuration.isPressed) { _, down in
                    if down {
                        Haptics.tap()
                        glow = 1
                    } else {
                        withAnimation(.easeOut(duration: 0.32)) { glow = 0 }
                    }
                }
        }
    }
}
