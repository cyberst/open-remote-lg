import SwiftUI
import LGKit

/// Finds TVs on the network or accepts a typed IP address.
/// Used for setup step 1 and for "Add TV…" in the TV menu.
struct ConnectView: View {
    enum Context {
        case onboarding
        /// Presented as the Add TV sheet: hands the chosen TV back so the sheet can dismiss before pairing starts.
        case add(onSelect: (TVDevice) -> Void)
    }

    let context: Context
    @Environment(TVSession.self) private var session
    @State private var showIPEntry = false
    @State private var ip = ""
    @State private var probing = false
    @State private var notFoundHost: String?

    private var isOnboarding: Bool { if case .onboarding = context { true } else { false } }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if isOnboarding { hero }
                if isOnboarding && !session.devices.isEmpty {
                    card(title: "Your TVs", trailing: nil) {
                        ForEach(session.devices) { device in
                            row(device, subtitle: device.modelName ?? device.host)
                            if device.id != session.devices.last?.id { Divider().padding(.leading, 64) }
                        }
                    }
                }
                discoveredCard
                actions
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(isOnboarding ? "" : "Add TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.startDiscovery() }
        .onDisappear { session.stopDiscovery() }
        .alert("Enter IP Address", isPresented: $showIPEntry) {
            TextField("192.168.1.20", text: $ip)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") { Task { await probe() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll find it on the TV under Settings ▸ Network (Wi‑Fi or wired connection ▸ Advanced).")
        }
        .alert("No TV Answered", isPresented: Binding(get: { notFoundHost != nil }, set: { if !$0 { notFoundHost = nil } })) {
            Button("Try Anyway") {
                if let host = notFoundHost { select(TVDevice(id: "host:\(host)", name: "LG TV", host: host)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing at \(notFoundHost ?? "") identified itself as an LG TV. Check the address and that the TV is on.")
        }
    }

    // MARK: Sections

    /// Setup step 1 intro: one line, then straight to the TVs.
    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "av.remote.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accent.gradient))
                .accessibilityHidden(true)
            Text("Pick your TV")
                .font(.title.weight(.bold))
            Text("Your \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") and TV need to be on the same Wi‑Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var discoveredCard: some View {
        let found = session.discovered.filter { d in !(isOnboarding && session.devices.contains { TVSession.isSameTV($0, d) }) }
        return card(title: "On Your Wi‑Fi", trailing: AnyView(discoveryStatus)) {
            if found.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: session.isDiscovering ? "dot.radiowaves.left.and.right" : "tv.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: session.isDiscovering)
                        .frame(width: 34)
                    Text(session.isDiscovering ? "Looking for LG TVs…" : "No TVs found. Make sure the TV is on and connected to the same Wi‑Fi.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(14)
            } else {
                ForEach(found) { device in
                    row(device, subtitle: [device.modelName, device.host].compactMap { $0 }.joined(separator: " · "))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    if device.id != found.last?.id { Divider().padding(.leading, 64) }
                }
            }
        }
        .animation(Theme.smooth, value: found)
    }

    @ViewBuilder private var discoveryStatus: some View {
        if session.isDiscovering {
            ProgressView().controlSize(.small)
        } else {
            Button("Search Again") { Haptics.tap(); session.startDiscovery() }
                .font(.footnote.weight(.semibold))
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            actionButton(probing ? "Looking…" : "Enter IP Address", symbol: "number", busy: probing) {
                ip = ""; showIPEntry = true
            }
            .disabled(probing)
            NavigationLink {
                TroubleshootingView()
            } label: {
                Text("Can't find your TV?")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 8)
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                if busy { ProgressView() } else {
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
        }
        .buttonStyle(KeyStyle(shape: .rounded))
        .frame(height: 58)
    }

    // MARK: Building blocks

    private func card<Content: View>(title: String, trailing: AnyView?, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) {
            HStack {
                SectionCaption(text: title)
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .surface(cornerRadius: Theme.corner)
        }
    }

    private func row(_ device: TVDevice, subtitle: String) -> some View {
        let busy = session.current?.id == device.id && (session.isConnecting || session.pairingRequest != nil)
        return Button { Haptics.tap(); select(device) } label: {
            HStack(spacing: 14) {
                Image(systemName: "tv")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if busy { ProgressView() } else { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("\(device.name), \(subtitle)")
        .accessibilityHint("Connect to this TV")
    }

    // MARK: Actions

    private func select(_ device: TVDevice) {
        switch context {
        case .onboarding:
            Task { await session.connect(to: device) }
        case .add(let onSelect):
            onSelect(device)
        }
    }

    private func probe() async {
        let host = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        probing = true
        defer { probing = false }
        if let found = await session.probe(host: host) {
            select(found)
        } else {
            notFoundHost = host
        }
    }
}

#Preview {
    NavigationStack { ConnectView(context: .onboarding) }.environment(TVSession.preview(connected: false))
}
