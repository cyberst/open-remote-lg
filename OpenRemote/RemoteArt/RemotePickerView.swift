import SwiftUI
import LGKit

/// "Select a remote": a carousel of the remote pictures with the neighbours peeking. Tapping the centred remote
/// saves it (`UserDefaults "remote.selectedID"`) and calls `onDone`.
/// Opens on the remote that shipped with `tvModelYear` (no match: the newest Magic Remote). With `tvModelYear: nil`
/// (e.g. "Change Remote…") it opens on the current choice, falling back to the newest Magic Remote.
struct RemotePickerView: View {
    private let remotes: [RemoteSpec]
    private let onDone: () -> Void
    @State private var centredID: String?
    @State private var showHelp = false

    /// The reference look: indigo accents on a soft lavender backdrop.
    static let indigo = Color(red: 0.36, green: 0.37, blue: 0.93)

    init(tvModelYear: Int?, onDone: @escaping () -> Void) {
        let catalog = RemoteCatalog.shared
        remotes = catalog.remotes
        self.onDone = onDone
        let saved = UserDefaults.standard.string(forKey: RemoteCatalog.selectedIDKey).flatMap { catalog.remote(id: $0)?.id }
        let start = tvModelYear == nil ? (saved ?? catalog.defaultID(forModelYear: nil)) : catalog.defaultID(forModelYear: tvModelYear)
        _centredID = State(initialValue: start ?? remotes.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 20)
                .padding(.horizontal, 24)
            GeometryReader { geo in
                carousel(in: geo.size)
            }
            .padding(.top, 12)
            PageDots(count: remotes.count, index: remotes.firstIndex { $0.id == centredID } ?? 0)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .background(SoftBackground().ignoresSafeArea())
        .sheet(isPresented: $showHelp) { RemoteHelpSheet() }

    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Select a remote")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Button { showHelp = true } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Self.indigo, lineWidth: 2))
                    .foregroundStyle(Self.indigo)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About remotes")
        }
        .frame(maxWidth: .infinity)
    }

    private func carousel(in size: CGSize) -> some View {
        let slotWidth = size.width * 0.5
        // Each remote fits a box of ~44% of the screen width and the full available height.
        let boxWidth = size.width * 0.44, boxHeight = size.height
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(remotes) { remote in
                    let fit = fitted(remote, in: CGSize(width: boxWidth, height: boxHeight))
                    Button {
                        if centredID == remote.id {
                            Haptics.success()
                            UserDefaults.standard.set(remote.id, forKey: RemoteCatalog.selectedIDKey)
                            onDone()
                        } else {
                            Haptics.tick()
                            withAnimation(.smooth) { centredID = remote.id }
                        }
                    } label: {
                        RemoteThumbnail(spec: remote, size: fit)
                            .frame(width: slotWidth, height: size.height)
                    }
                    .buttonStyle(ThumbnailPressStyle())
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(phase.isIdentity ? 1 : 0.82)
                            .opacity(phase.isIdentity ? 1 : 0.55)
                            .saturation(phase.isIdentity ? 1 : 0.4)
                            .blur(radius: phase.isIdentity ? 0 : 0.6)
                    }
                    .id(remote.id)
                    .accessibilityLabel("\(remote.name), \(remote.years)")
                    .accessibilityHint(centredID == remote.id ? Text("Double-tap to use this remote.") : Text("Double-tap to show this remote."))
                    .accessibilityAddTraits(centredID == remote.id ? .isSelected : [])
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, (size.width - slotWidth) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centredID, anchor: .center)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .onChange(of: centredID) { _, _ in Haptics.tick() }
    }

    private func fitted(_ remote: RemoteSpec, in box: CGSize) -> CGSize {
        let aspect = remote.aspectRatio
        let h = min(box.height, box.width / aspect)
        return CGSize(width: h * aspect, height: h)
    }
}

private struct RemoteThumbnail: View {
    let spec: RemoteSpec
    let size: CGSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = RemoteImageStore.image(for: spec, maxPixelHeight: Int((size.height * displayScale).rounded(.up))) {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size.width * 0.4, style: .continuous).fill(Color(white: 0.12))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 12)
    }
}

private struct ThumbnailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Page dots under the carousel; the current one is larger and indigo.
private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? RemotePickerView.indigo : RemotePickerView.indigo.opacity(0.22))
                    .frame(width: i == index ? 11 : 6, height: i == index ? 11 : 6)
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.2), value: index)
        .accessibilityElement()
        .accessibilityLabel("Remote \(index + 1) of \(count)")
    }
}

/// The (?) sheet: what the picture is for, pointing with the phone, and app keys.
private struct RemoteHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("appletvremote.gen4", "Pick the one you know",
                    "Choose the remote that looks like the one that came with your TV. If you can’t find an exact match, choose another remote—it will work with your TV too. You can change it later from the TV menu › Change Remote.")
                row("cursorarrow.rays", "Point with your phone",
                    "Tap Point in the corner of the remote, then move your phone to move the TV pointer. OK clicks where it points. Pressing an arrow key hides the pointer until you move the phone again.")
                row("app.badge", "App keys",
                    "The white shortcut keys show your TV's own apps. Touch and hold one to choose which app it opens.")
                row("wifi.slash", "Keys that don't work over Wi‑Fi",
                    "A few keys have no network command. They stay on the remote and say so when tapped.")
            }
            .navigationTitle("Remotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(RemotePickerView.indigo)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
