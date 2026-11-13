import SwiftUI
import LGKit

/// Installed TV apps in a grid, in the order the user arranged them (A–Z until then; see `AppOrder`).
/// Touch and hold an app, then drag it to rearrange. Search is revealed by pulling down. The foreground app is ringed.
struct AppsView: View {
    @Environment(TVSession.self) private var session
    @State private var apps: [TVApp] = []
    @State private var order = AppOrder.saved
    @State private var dragging: String?
    @State private var confirmSort = false
    @State private var query = ""
    @State private var foreground: String?
    @State private var failed: String?
    @State private var loading = false
    @FocusState private var searchFocused: Bool

    private static let searchHeight: CGFloat = 52

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var arranged: [TVApp] { order.arranged(apps) }
    private var filtered: [TVApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? arranged : arranged.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        searchField
                            .frame(height: Self.searchHeight, alignment: .top)
                            .id("search")
                        VStack(spacing: 20) {
                            grid
                            statusView
                            if !searching && !apps.isEmpty { arrangeFooter }
                        }
                        .padding(.top, 4)
                        .id("content")
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 24)
                    // Always tall enough to scroll the search field out of sight, so it hides until pulled down.
                    .frame(minHeight: geo.size.height + Self.searchHeight, alignment: .top)
                }
                // Ends a drag released between tiles (tiles handle their own drops).
                .onDrop(of: [.text], delegate: TileDrop(target: nil, dragging: $dragging, move: move))
                .scrollDismissesKeyboard(.immediately)
                .scrollIndicators(.hidden)
                .onAppear {
                    if !searching { proxy.scrollTo("content", anchor: .top) }
                }
            }
        }
        .task(id: session.isConnected) { await load() }
        .task(id: session.isConnected) { await observeForeground() }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 104), spacing: 12, alignment: .top)], spacing: 18) {
            ForEach(filtered) { app in
                AppTile(app: app, isForeground: app.id == foreground, launch: { launch(app) },
                        moveEarlier: searching ? nil : { step(app, by: -1) },
                        moveLater: searching ? nil : { step(app, by: 1) })
                    .modifier(Rearrangeable(id: app.id, enabled: !searching, dragging: $dragging, move: move))
            }
        }
    }

    /// How to rearrange (until the user has), then a way back to A–Z.
    @ViewBuilder private var arrangeFooter: some View {
        if order.isCustom {
            Button("Sort A–Z") { confirmSort = true }
                .font(.footnote)
                .confirmationDialog("Sort apps A–Z?", isPresented: $confirmSort, titleVisibility: .visible) {
                    Button("Sort A–Z", role: .destructive, action: sortAlphabetically)
                } message: {
                    Text("Your arrangement will be replaced.")
                }
        } else {
            Text("Touch and hold an app, then drag it to rearrange.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var statusView: some View {
        if let failed {
            status(symbol: "exclamationmark.triangle", text: failed, retry: true)
        } else if loading && apps.isEmpty {
            ProgressView().padding(.top, 40)
        } else if !apps.isEmpty && filtered.isEmpty {
            status(symbol: "magnifyingglass", text: "No apps match “\(query)”.", retry: false)
        }
    }

    private func status(symbol: String, text: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if retry { Button("Try Again") { Task { await load() } }.buttonStyle(.bordered) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Actions

    private func launch(_ app: TVApp) {
        Haptics.press()
        searchFocused = false
        foreground = app.id
        let id = app.id
        session.send { try await $0.launchApp(id: id, params: nil) }
    }

    /// Puts `id` in `target`'s place and remembers the new order.
    private func move(_ id: String, onto target: String) {
        let new = order.moving(id, to: target, among: apps)
        guard new != order else { return }
        Haptics.tick()
        withAnimation(Theme.smooth) { order = new }
        AppOrder.saved = new
    }

    /// Swaps an app with its neighbour (VoiceOver's Move Earlier / Move Later).
    private func step(_ app: TVApp, by offset: Int) {
        let list = arranged
        guard let i = list.firstIndex(of: app), list.indices.contains(i + offset) else { return }
        move(app.id, onto: list[i + offset].id)
    }

    private func sortAlphabetically() {
        Haptics.tick()
        withAnimation(Theme.smooth) { order = AppOrder() }
        AppOrder.saved = order
    }

    private func load() async {
        order = AppOrder.saved
        dragging = nil
        guard session.isConnected else { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await session.run { try await $0.apps() }
            apps = list
            failed = nil
            // Newly installed apps take their place at the end of a custom order and keep it from now on.
            let known = order.including(list)
            if known != order { order = known; AppOrder.saved = known }
        } catch {
            if apps.isEmpty { failed = "Couldn't load the app list." }
        }
    }

    private func observeForeground() async {
        guard session.isConnected, let tv = session.tv else { return }
        for await id in tv.observeForegroundApp() {
            withAnimation(Theme.smooth) { foreground = id }
        }
    }
}

struct AppTile: View {
    let app: TVApp
    var iconSize: CGFloat = 64
    let isForeground: Bool
    let launch: () -> Void
    var moveEarlier: (() -> Void)?
    var moveLater: (() -> Void)?

    var body: some View {
        Button(action: launch) {
            VStack(spacing: 7) {
                AppIcon(app: app)
                    .frame(width: iconSize, height: iconSize)
                    .overlay {
                        if isForeground {
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 2.5)
                                .padding(-4.5)
                        }
                    }
                Text(app.title)
                    .font(.caption.weight(isForeground ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel(app.title)
        .accessibilityValue(isForeground ? "Open on TV" : "")
        .accessibilityAddTraits(isForeground ? .isSelected : [])
        .accessibilityActions {
            if let moveEarlier { Button("Move Earlier", action: moveEarlier) }
            if let moveLater { Button("Move Later", action: moveLater) }
        }
    }
}

/// Touch-and-hold drag to rearrange: the dragged tile takes the place of each tile it passes over.
private struct Rearrangeable: ViewModifier {
    let id: String
    let enabled: Bool
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [.text], delegate: TileDrop(target: id, dragging: $dragging, move: move))
        } else {
            content
        }
    }
}

/// Drops onto a tile (`target`) or between tiles (`nil`). Only accepts drags that started on a tile here.
private struct TileDrop: DropDelegate {
    let target: String?
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, let target, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// App icon from the TV, or a monogram placeholder when the TV doesn't provide one.
/// Loaded through the TV client (not `AsyncImage`): over wss the TV serves icons with a self-signed certificate.
struct AppIcon: View {
    let app: TVApp
    @Environment(TVSession.self) private var session
    @State private var icon: UIImage?

    var body: some View {
        ZStack {
            placeholder
            if let icon {
                Image(uiImage: icon).resizable().scaledToFill().transition(.opacity)
            }
        }
        .task(id: app.iconURL) { await loadIcon() }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .keyShadow()
        .accessibilityHidden(true)
    }

    private func loadIcon() async {
        guard let url = app.iconURL, icon == nil else { return }
        guard let data = try? await session.run({ try await $0.resourceData(from: url) }),
              let image = UIImage(data: data) else { return }
        withAnimation(.easeOut(duration: 0.2)) { icon = image }
    }

    private var placeholder: some View {
        let base = Self.palette[Self.stableHash(app.id) % Self.palette.count]
        return LinearGradient(colors: [base, base.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Text(monogram)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.4)
                    .padding(4)
            }
    }

    private var monogram: String {
        let words = app.title.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.86), Color(red: 0.20, green: 0.62, blue: 0.62),
        Color(red: 0.86, green: 0.45, blue: 0.30), Color(red: 0.55, green: 0.38, blue: 0.80),
        Color(red: 0.28, green: 0.56, blue: 0.36), Color(red: 0.80, green: 0.34, blue: 0.48),
        Color(red: 0.32, green: 0.50, blue: 0.70), Color(red: 0.64, green: 0.52, blue: 0.30),
    ]

    /// `hashValue` is randomised per launch; colours should stay put.
    private static func stableHash(_ s: String) -> Int {
        Int(s.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 9973)
    }
}

#Preview {
    AppsView().environment(TVSession.preview()).background(Theme.background)
}
