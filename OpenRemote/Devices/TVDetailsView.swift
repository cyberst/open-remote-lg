import SwiftUI
import LGKit

/// Model, software and network details of a TV. Live values come from `info()` when it's the connected TV.
struct TVDetailsView: View {
    let deviceID: String
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var info: TVInfo?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmForget = false

    private var device: TVDevice? {
        session.devices.first { $0.id == deviceID } ?? (session.current?.id == deviceID ? session.current : nil)
    }
    private var isLive: Bool { session.current?.id == deviceID && session.isConnected }

    var body: some View {
        List {
            if let device {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "tv")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(Theme.accent.opacity(0.14)))
                        Text(device.name).font(.title2.weight(.bold))
                        Text(isLive ? "Connected" : "Not connected")
                            .font(.subheadline)
                            .foregroundStyle(isLive ? Theme.connected : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Television") {
                    value("Model", info?.modelName ?? device.modelName)
                    value("webOS", info?.webOSVersion ?? device.webOSVersion)
                    value("Firmware", info?.firmwareVersion)
                    ForEach(extraKeys, id: \.self) { key in value(key, info?.extra[key]) }
                }

                Section("Network") {
                    value("IP Address", device.host)
                    let macs = (info?.macAddresses.isEmpty == false ? info?.macAddresses : nil) ?? device.macAddresses
                    if macs.isEmpty {
                        value("MAC Address", nil)
                    } else {
                        ForEach(Array(macs.enumerated()), id: \.offset) { i, mac in
                            value(macs.count > 1 ? "MAC Address \(i + 1)" : "MAC Address", mac)
                        }
                    }
                    if let last = device.lastConnected {
                        LabeledContent("Last Connected") { Text(last, format: .relative(presentation: .named)) }
                    }
                }

                if !device.isDemo {
                    Section {
                        Button("Rename") { newName = device.name; renaming = true }
                        Button("Forget TV", role: .destructive) { confirmForget = true }
                    }
                }
            } else {
                ContentUnavailableView("TV Removed", systemImage: "tv.slash")
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isLive) {
            guard isLive else { return }
            info = try? await session.run { try await $0.info() }
        }
        .alert("Rename TV", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if let device { session.rename(device, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Forget \(device?.name ?? "TV")?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget TV", role: .destructive) {
                guard let device else { return }
                Task { await session.forget(device); dismiss() }
            }
        } message: {
            Text("You'll need to accept the prompt on the TV again to reconnect.")
        }
    }

    private var extraKeys: [String] { (info?.extra.keys).map { $0.sorted() } ?? [] }

    private func value(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value ?? "—")
                .textSelection(.enabled)
                .monospacedDigit()
        }
        .contextMenu {
            if let value { Button { UIPasteboard.general.string = value } label: { Label("Copy", systemImage: "doc.on.doc") } }
        }
    }
}

#Preview {
    NavigationStack { TVDetailsView(deviceID: "demo") }.environment(TVSession.preview())
}
