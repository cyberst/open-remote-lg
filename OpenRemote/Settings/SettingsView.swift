import SwiftUI
import LGKit

/// The one Settings screen: feel, pointer, TV actions, saved TVs and About.
struct SettingsView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PrefKey.haptics) private var haptics = true
    @AppStorage(PrefKey.keepAwake) private var keepAwake = false
    @State private var renaming: TVDevice?
    @State private var newName = ""
    @State private var forgetting: TVDevice?
    /// The TV's picture is off (from the TV's power state, or our own last Screen Off / Screen On).
    @State private var screenIsOff = false

    /// Placeholder until the public repository URL is final.
    static let sourceURL = URL(string: "https://github.com/")!  // TODO(Release): real repository URL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Haptic Feedback", isOn: $haptics)
                Toggle("Keep Screen Awake", isOn: $keepAwake)
            } footer: {
                Text("Keep Screen Awake stops your iPhone or iPad from locking while Open Remote is open.")
            }

            PointerSettingsSection()

            Section {
                Button {
                    Haptics.press()
                    // The label follows `observeScreenOff()`, which updates once the TV accepts the command.
                    if screenIsOff {
                        session.send { try await $0.screenOn() }
                    } else {
                        session.send { try await $0.screenOff() }
                    }
                } label: {
                    Label {
                        Text(screenIsOff ? "Screen On" : "Screen Off")
                    } icon: {
                        Image(systemName: screenIsOff ? "tv" : "rectangle.slash").foregroundStyle(Theme.accent)
                    }
                }
                .tint(.primary)
                .contentTransition(.symbolEffect(.replace))
                .task(id: session.observationKey) {
                    screenIsOff = false
                    guard let tv = session.tv else { return }
                    for await off in tv.observeScreenOff() { screenIsOff = off }
                }
                NavigationLink {
                    SleepTimerView()
                } label: {
                    Label("Sleep Timer", systemImage: "moon.zzz")
                }
            } header: {
                Text(session.current?.name ?? "TV")
            } footer: {
                Text(screenIsOff
                     ? "The picture is off and the sound keeps playing. Tap Screen On, or press any key on the remote, to bring it back."
                     : "Screen Off keeps the sound playing. Press any key on the remote to turn the picture back on.")
            }

            tvsSection

            Section {
                LabeledContent("Version", value: version)
                Link(destination: Self.sourceURL) {
                    LabeledContent("Source Code") { Image(systemName: "arrow.up.right.square") }
                }
                .foregroundStyle(.primary)
                NavigationLink("Privacy") { PrivacyView() }
                NavigationLink("Help & Troubleshooting") { TroubleshootingView() }
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            } header: {
                Text("About")
            } footer: {
                Text("Open Remote is free, open-source software. Not affiliated with LG Electronics.")
                    .padding(.top, 6)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .alert("Rename TV", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let d = renaming { session.rename(d, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "TV")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Forget TV", role: .destructive) {
                if let d = forgetting { Task { await session.forget(d) } }
            }
        } message: {
            Text("You'll need to accept the prompt on the TV again to reconnect.")
        }
    }

    // MARK: TVs

    private var tvsSection: some View {
        Section {
            if session.devices.isEmpty {
                Text("No saved TVs yet.").foregroundStyle(.secondary)
            }
            ForEach(session.devices) { device in
                NavigationLink {
                    TVDetailsView(deviceID: device.id)
                } label: {
                    tvRow(device)
                }
                .swipeActions(edge: .trailing) {
                    Button("Forget", role: .destructive) { forgetting = device }
                    Button("Rename") { newName = device.name; renaming = device }.tint(.indigo)
                }
                .contextMenu {
                    Button { newName = device.name; renaming = device } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { forgetting = device } label: { Label("Forget TV", systemImage: "trash") }
                }
            }
        } header: {
            Text("TVs")
        } footer: {
            if !session.devices.isEmpty { Text("Swipe a TV to rename or forget it. Add TVs from the menu under the TV name.") }
        }
    }

    private func tvRow(_ device: TVDevice) -> some View {
        let isCurrent = session.current?.id == device.id
        let detail = [device.modelName, device.host].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCurrent ? .white : Theme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isCurrent ? Theme.accent : Theme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isCurrent ? "Current TV" : "")
    }
}

/// What the app does with your data, including how voice commands are recognised.
struct PrivacyView: View {
    /// Only read for its capabilities (on-device recognition, language); never starts listening here.
    @State private var speech = SpeechRecognizer()

    var body: some View {
        List {
            Section {
                Label {
                    Text("No accounts, ads, analytics or tracking. Open Remote only talks to your TV, on your own network.")
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.accent)
                }
            }
            Section {
                if speech.supportsOnDevice {
                    Label {
                        Text("Speech is recognised on this device. Your voice never leaves it.")
                    } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                    }
                } else {
                    Label {
                        Text("This device can't recognise speech on its own, so while you give a command your voice is sent to Apple to turn it into text, under Apple's privacy policy.")
                    } icon: {
                        Image(systemName: "network").foregroundStyle(Theme.accent)
                    }
                }
                Label {
                    Text("Open Remote never stores or shares your voice. Only the resulting command is sent — to your TV, on your network.")
                } icon: {
                    Image(systemName: "waveform").foregroundStyle(Theme.accent)
                }
            } header: {
                Text("Voice Commands")
            } footer: {
                if !speech.usesDeviceLanguage { Text("Voice commands work in English for now.") }
            }
            Section {
                Label {
                    Text("Photos and videos you cast are served from this device straight to the TV while casting, and nowhere else.")
                } icon: {
                    Image(systemName: "photo.tv").foregroundStyle(Theme.accent)
                }
            } header: {
                Text("Casting")
            }
        }
        .font(.subheadline)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Open Remote is built entirely with Apple's frameworks and contains no third-party code.")
                Text("LG, webOS and LG Connect Apps are trademarks of LG Electronics Inc. Open Remote is an independent project and is not affiliated with, endorsed by or sponsored by LG Electronics.")
                Divider()
                Text("MIT License").font(.headline)
                Text(Self.mit)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
            .padding(Theme.gutter)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let mit = """
    Copyright (c) 2026 Open Remote contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

#Preview {
    NavigationStack { SettingsView() }.environment(TVSession.preview())
}
