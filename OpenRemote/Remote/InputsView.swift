import SwiftUI
import LGKit

/// TV sources in one list, in the TV's order: connected ones lit with the current one highlighted, unplugged ones dimmed. Tap to switch.
struct InputsView: View {
    @Environment(TVSession.self) private var session
    /// Called after a source is chosen (the Inputs sheet closes itself with it).
    var onSelect: (() -> Void)? = nil
    @State private var inputs: [TVInput] = []
    @State private var foreground: String?
    @State private var failed = false
    @State private var loading = false

    private static let liveTV = "com.webos.app.livetv"

    private struct Source: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let appID: String?
        let input: TVInput?
        var dimmed = false
    }

    private var sources: [Source] {
        [Source(id: "livetv", title: String(localized: "Live TV"), symbol: "antenna.radiowaves.left.and.right",
                appID: Self.liveTV, input: nil)]
            + inputs.map(Self.source)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                list
                if failed {
                    Label("Couldn't load inputs from the TV.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else if loading && inputs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .task(id: session.isConnected) { await load() }
        .task(id: session.isConnected) { await observeForeground() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { Divider().padding(.leading, 64) }
                row(source)
            }
        }
        .background(Theme.padBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .surface(cornerRadius: Theme.corner)
    }

    private func row(_ source: Source) -> some View {
        let dimmed = source.dimmed
        let active = source.appID != nil && source.appID == foreground
        return Button { select(source) } label: {
            HStack(spacing: 14) {
                Image(systemName: source.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(active ? .white : Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Theme.accent : Theme.accent.opacity(0.13)))
                Text(source.title)
                    .font(.body.weight(active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if active {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(active ? Theme.accent.opacity(0.08) : .clear)
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(source.title)
        .accessibilityValue(dimmed ? String(localized: "Nothing connected") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func select(_ source: Source) {
        Haptics.tap()
        withAnimation(Theme.smooth) { foreground = source.appID }
        if let input = source.input {
            let id = input.id
            session.send { try await $0.switchInput(id: id) }
        } else if let app = source.appID {
            session.send { try await $0.launchApp(id: app, params: nil) }
        }
        onSelect?()
    }

    private static func source(_ input: TVInput) -> Source {
        Source(id: input.id, title: input.label, symbol: symbol(for: input), appID: input.appId, input: input,
               dimmed: !input.connected)
    }

    static func symbol(for input: TVInput) -> String {
        let label = input.label.lowercased()
        if ["playstation", "xbox", "switch", "nintendo", "console", "game"].contains(where: label.contains) {
            return "gamecontroller"
        }
        if ["apple tv", "fire", "chromecast", "roku", "shield"].contains(where: label.contains) { return "appletv" }
        if label.contains("pc") || label.contains("computer") || label.contains("mac") { return "desktopcomputer" }
        let id = input.id.uppercased()
        if id.contains("HDMI") { return "cable.connector.horizontal" }
        if id.contains("AV") || id.contains("COMP") { return "cable.coaxial" }
        if id.contains("USB") { return "externaldrive" }
        return "rectangle.on.rectangle"
    }

    private func load() async {
        guard session.isConnected else { return }
        loading = true
        defer { loading = false }
        do {
            inputs = try await session.run { try await $0.inputs() }
            failed = false
        } catch {
            failed = inputs.isEmpty
        }
    }

    private func observeForeground() async {
        guard session.isConnected, let tv = session.tv else { return }
        for await id in tv.observeForegroundApp() {
            withAnimation(Theme.smooth) { foreground = id }
        }
    }
}

#Preview {
    InputsView().environment(TVSession.preview()).background(Theme.background)
}
