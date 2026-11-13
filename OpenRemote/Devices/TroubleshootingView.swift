import SwiftUI

struct TroubleshootingView: View {
    @Environment(\.openURL) private var openURL

    private struct Tip: Identifiable {
        let symbol: String
        let title: String
        let text: LocalizedStringKey
        var id: String { title }
    }

    private let tips: [Tip] = [
        Tip(symbol: "wifi", title: "Same Wi‑Fi network",
            text: "Your iPhone or iPad and the TV must be on the same network. Guest networks and routers with “client isolation” block devices from seeing each other."),
        Tip(symbol: "power", title: "TV switched on",
            text: "Turn the TV on with its remote. Most TVs can't be found while they're in standby."),
        Tip(symbol: "link", title: "LG Connect Apps",
            text: "On older TVs, turn on **LG Connect Apps** in the TV's network settings. Newer TVs have it on by default."),
        Tip(symbol: "bolt.horizontal", title: "Turning the TV on from the app",
            text: "Enable **Mobile TV On** (also called **Turn on via Wi‑Fi**) in the TV's General or Connection settings. Some TVs only wake when connected by cable or with Quick Start enabled."),
        Tip(symbol: "number", title: "Connect by IP address",
            text: "If the TV still doesn't show up, look up its IP address in the TV's network settings and use **Enter IP Address**."),
        Tip(symbol: "checkmark.shield", title: "Pairing prompt",
            text: "The first time you connect, the TV asks to allow Open Remote. If you declined by accident, connect again and choose **Accept**."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(tips) { tip in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: tip.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tip.title).font(.body.weight(.semibold))
                            Text(tip.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Local Network access", systemImage: "network").font(.body.weight(.semibold))
                    Text("Open Remote needs Local Network access to find and talk to your TV. If you tapped “Don't Allow”, turn it back on in Settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Can't Find Your TV?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { TroubleshootingView() }
}
