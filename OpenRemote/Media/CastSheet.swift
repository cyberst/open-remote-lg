import PhotosUI
import SwiftUI
import LGKit

/// Cast photos and videos from this device.
/// Contract: `CastSheet()` takes no arguments, reads `@Environment(TVSession.self)` and is presented as a sheet.
/// On appear it opens the iOS photo picker straight away (unless something is already casting); once items are
/// picked it shows the small "On TV" controls. Cancelling the picker with nothing casting closes the sheet.
/// It sets its own detents; present it without `.presentationDetents`.
struct CastSheet: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var cast = CastController.shared
    @State private var picking = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var openedPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if cast.isActive {
                    OnTVControls(cast: cast, stop: stop)
                } else {
                    placeholder
                }
            }
            .navigationTitle("On TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if cast.isActive {
                        Button { picking = true } label: { Label("Add Photos or Videos", systemImage: "plus") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents(cast.isActive ? [.height(500), .large] : [.height(260)])
        .presentationDragIndicator(.visible)
        .photosPicker(isPresented: $picking, selection: $picks, maxSelectionCount: 50, selectionBehavior: .ordered,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: picks) { _, new in
            guard !new.isEmpty else { return }
            cast.add(new, session: session)
            picks = []
        }
        .onChange(of: picking) { _, isPicking in
            guard !isPicking else { return }
            // Picker closed: if nothing was picked and nothing is casting, there's nothing to show.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !cast.isActive && !picking { dismiss() }
            }
        }
        .onChange(of: session.current?.id) { _, id in cast.tvChanged(to: id) }
        .task(id: session.isConnected) {
            // Opens once, as soon as a TV is connected (right away in the usual case).
            guard !openedPicker, !cast.isActive, session.isConnected else { return }
            openedPicker = true
            // Let the sheet finish presenting before stacking the picker on it.
            try? await Task.sleep(for: .milliseconds(250))
            picking = true
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: session.isConnected ? "photo.on.rectangle.angled" : "tv.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            if session.isConnected {
                Button("Choose Photos & Videos") { picking = true }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Text("Connect to a TV to cast photos and videos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stop() {
        Haptics.press()
        cast.stopCasting()
        dismiss()
    }
}

// MARK: - On TV

private struct OnTVControls: View {
    let cast: CastController
    let stop: () -> Void

    private var isVideo: Bool { cast.current?.kind == .video }
    private var multiple: Bool { cast.items.count > 1 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CastStage(cast: cast)
                    .frame(maxWidth: 340)

                HStack(spacing: 32) {
                    CastButton("backward.end.fill", label: "Previous") { cast.previous() }
                        .disabled(!multiple)
                    if isVideo {
                        CastButton(cast.videoPaused ? "play.fill" : "pause.fill",
                                   label: cast.videoPaused ? "Play video" : "Pause video",
                                   prominent: true, size: Theme.buttonSize) { cast.toggleVideoPause() }
                            .disabled(cast.phase != .showing)
                    }
                    CastButton("forward.end.fill", label: "Next") { cast.next() }
                        .disabled(!multiple)
                }

                if multiple {
                    Toggle(isOn: Binding(get: { cast.slideshowRunning }, set: { _ in Haptics.tick(); cast.toggleSlideshow() })) {
                        Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Theme.padBackground, in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
                }

                if let error = cast.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(role: .destructive, action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.vertical, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// What the TV shows: the current item's thumbnail, its status, position in the queue and video progress.
private struct CastStage: View {
    let cast: CastController

    var body: some View {
        ZStack {
            Color.black
            if let image = cast.current?.thumbnail {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: cast.current?.kind == .video ? "film" : "photo")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.5))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
        .overlay(alignment: .topLeading) { CastStatusPill(cast: cast).padding(10) }
        .overlay(alignment: .topTrailing) {
            if let i = cast.currentIndex, cast.items.count > 1 {
                Text("\(i + 1) / \(cast.items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(10)
                    .accessibilityLabel(Text("Item \(i + 1) of \(cast.items.count)"))
            }
        }
        .overlay(alignment: .bottom) {
            if cast.current?.kind == .video, cast.phase == .showing, let status = cast.videoStatus,
               let duration = status.duration, duration > 0 {
                VideoProgress(position: status.position ?? 0, duration: duration).padding(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: cast.currentIndex)
    }
}

private struct CastStatusPill: View {
    let cast: CastController

    var body: some View {
        HStack(spacing: 6) {
            switch cast.phase {
            case .showing:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(cast.slideshowRunning ? "Slideshow on TV" : "On TV")
            case .sending:
                ProgressView().controlSize(.mini).tint(.white)
                Text("Sending to TV…")
            case .waiting:
                ProgressView().controlSize(.mini).tint(.white)
                Text(preparingText)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Couldn't show on TV")
            case .idle:
                Text("Not on TV")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var preparingText: LocalizedStringKey {
        if case .preparing(let p) = cast.current?.state, p > 0 { return "Preparing \(Int(p * 100))%" }
        return "Preparing…"
    }
}

private struct VideoProgress: View {
    let position: TimeInterval
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(position))
            ProgressView(value: min(position, duration), total: duration).tint(.white)
            Text(Self.format(duration))
        }
        .font(.caption2.monospacedDigit().weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Video position"))
        .accessibilityValue(Text("\(Self.format(position)) of \(Self.format(duration))"))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Round SF Symbol button with a haptic tap.
private struct CastButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var prominent = false
    var size: CGFloat = Theme.smallButtonSize
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ symbol: String, label: LocalizedStringKey, prominent: Bool = false, size: CGFloat = Theme.smallButtonSize,
         action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.prominent = prominent; self.size = size; self.action = action
    }

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(Circle().fill(prominent ? Theme.accent : Theme.buttonBackground))
                .overlay(Circle().strokeBorder(Theme.stroke))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(CastPressStyle())
        .accessibilityLabel(Text(label))
    }
}

private struct CastPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        CastSheet().environment(TVSession.preview())
    }
}
