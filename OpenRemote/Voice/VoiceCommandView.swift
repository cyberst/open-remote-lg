import SwiftUI
import LGKit

/// Voice command sheet. Contract: `VoiceCommandView()` takes no arguments and reads `@Environment(TVSession.self)`.
struct VoiceCommandView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = VoiceCommandModel()
    @State private var showExamples = false
    @State private var autoDismiss = true
    @State private var pressStart: Date?
    @State private var suggestion = VoiceExamples.suggestions.randomElement() ?? "Open Netflix"
    #if DEBUG
    @State private var debugCommand = ""
    #endif

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .denied(let permission): PermissionDeniedView(permission: permission, openSettings: openSettings)
                case .consent:
                    ServerRecognitionNotice(
                        onContinue: { model.acceptServerRecognition(session: session) },
                        onDecline: { model.declineServerRecognition() })
                default: main
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Examples", systemImage: "questionmark.circle") { showExamples = true }
                        .accessibilityHint("Shows commands you can say")
                }
            }
            .sheet(isPresented: $showExamples) { VoiceExamplesView() }
        }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshPermission() } else { model.cancel() }
        }
        .task(id: model.phase) {
            guard case .done = model.phase, autoDismiss else { return }
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled, case .done = model.phase { dismiss() }
        }
        #if DEBUG
        .task { applyDebugLaunchArguments() }
        #endif
    }

    // MARK: - Main

    /// Fits the sheet at its default height; on very small screens (or large text) it scrolls instead of
    /// spilling under the navigation bar.
    private var main: some View {
        ViewThatFits(in: .vertical) {
            mainContent
            ScrollView { mainContent }.scrollBounceBehavior(.basedOnSize)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 14) {
            if !session.isConnected {
                Label("Connect to a TV to use voice commands.", systemImage: "tv.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.buttonBackground, in: Capsule())
            }
            Spacer(minLength: 0)
            statusLine
            transcript
            resultCard
            Spacer(minLength: 0)
            micButton
            Text(model.isListening ? "Pause when you're done, or tap to stop." : "Tap to talk, or hold while you speak.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if DEBUG
            if Self.showsDebugField { debugField }
            #endif
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.top, 8)
        .padding(.bottom, Theme.spacing)
    }

    private var statusLine: some View {
        Group {
            switch model.phase {
            case .listening: Label("Listening…", systemImage: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
            case .working: Label("Sending to your TV…", systemImage: "antenna.radiowaves.left.and.right")
            case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Label("Try again", systemImage: "arrow.counterclockwise")
            default: Text("Say a command")
            }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }

    private var transcript: some View {
        let text = model.displayedTranscript
        return Group {
            if text.isEmpty {
                Text(model.isListening ? "…" : "Try “\(suggestion)”")
                    .foregroundStyle(.tertiary)
            } else {
                Text("“\(text)”")
                    .foregroundStyle(.primary)
            }
        }
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 60)
        .animation(.easeOut(duration: 0.15), value: text)
        .accessibilityLabel(text.isEmpty ? (model.isListening ? "Listening" : "Try saying \(suggestion)") : "Heard: \(text)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var resultCard: some View {
        switch model.phase {
        case .working:
            ProgressView().controlSize(.large).frame(height: 52)
        case .done(let message):
            ResultCard(symbol: VoiceSymbols.symbol(for: model.lastIntent), message: message, tint: .green)
        case .failed(let message):
            VStack(spacing: 10) {
                ResultCard(symbol: "exclamationmark.bubble", message: message, tint: .orange)
                Button("See what you can say") { showExamples = true }
                    .font(.subheadline)
            }
        default:
            Color.clear.frame(height: 52)
        }
    }

    private var micButton: some View {
        MicButton(isListening: model.isListening, level: model.speech.level, isBusy: model.phase == .working)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressStart == nil else { return }
                        pressStart = .now
                        model.pressBegan(session: session)
                    }
                    .onEnded { _ in
                        model.pressEnded(heldFor: Date().timeIntervalSince(pressStart ?? .now))
                        pressStart = nil
                    }
            )
            .disabled(!session.isConnected || model.phase == .working)
            .opacity(session.isConnected ? 1 : 0.4)
            .accessibilityElement()
            .accessibilityLabel(model.isListening ? "Stop listening" : "Start listening")
            .accessibilityHint("Say a command such as “Open Netflix”. Listening stops when you pause.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggle(session: session) }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: - Debug (simulator has no real microphone input)

    #if DEBUG
    /// `-VoiceDebugField` shows a text field that runs typed commands (the simulator has no microphone).
    private static let showsDebugField = ProcessInfo.processInfo.arguments.contains("-VoiceDebugField")

    private var debugField: some View {
        HStack {
            TextField("Type a command (debug)", text: $debugCommand)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .autocorrectionDisabled()
                .onSubmit(runDebugCommand)
            Button("Run", action: runDebugCommand)
                .buttonStyle(.bordered)
                .disabled(debugCommand.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.callout)
    }

    private func runDebugCommand() {
        let text = debugCommand
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        debugCommand = ""
        Task { await model.execute(text, session: session) }
    }

    /// `-VoiceDebugState <state>` forces a UI state; `-VoiceDebugCommand "<text>"` runs a command end-to-end.
    private func applyDebugLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let state = value("-VoiceDebugState") { autoDismiss = false; model.applyDebugState(state) }
        if let command = value("-VoiceDebugCommand") {
            autoDismiss = false
            Task {
                // Wait for the demo connection to come up.
                for _ in 0..<20 where !session.isConnected { try? await Task.sleep(for: .milliseconds(100)) }
                await model.execute(command, session: session)
            }
        }
    }
    #endif
}

// MARK: - Pieces

private struct MicButton: View {
    let isListening: Bool
    let level: Double
    let isBusy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { ring in
                Circle()
                    .fill(Theme.accent.opacity(ring == 0 ? 0.12 : 0.2))
                    .scaleEffect(isListening ? 1.15 + Double(2 - ring) * 0.12 + (reduceMotion ? 0 : level * 0.35) : 0.9)
                    .opacity(isListening ? 1 : 0)
            }
            Circle()
                .fill(isListening ? Color.red : Theme.accent)
                .shadow(color: (isListening ? Color.red : Theme.accent).opacity(0.35), radius: 16, y: 6)
            Image(systemName: isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: isListening ? 34 : 42, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 104, height: 104)
        .frame(width: 150, height: 150)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .animation(.spring(duration: 0.3), value: isListening)
    }
}

private struct ResultCard: View {
    let symbol: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(message)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.padBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

private struct PermissionDeniedView: View {
    let permission: SpeechRecognizer.Permission
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "mic.slash.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if permission != .restricted {
                    Button(action: openSettings) {
                        Label("Open Settings", systemImage: "gear").frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Text("Everything else in Open Remote works without it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.spacing * 1.5)
            .padding(.top, 32)
        }
    }

    private var title: String {
        switch permission {
        case .deniedMicrophone: "Microphone access is off"
        case .restricted: "Voice commands are restricted"
        default: "Speech recognition is off"
        }
    }

    private var message: String {
        switch permission {
        case .deniedMicrophone:
            "To control your TV by voice, allow Open Remote to use the microphone in Settings. It's only used while you're giving a command."
        case .restricted:
            "Speech recognition is restricted on this device, for example by Screen Time. Ask the device's organizer to allow it."
        default:
            "To understand your commands, allow Speech Recognition for Open Remote in Settings."
        }
    }
}

private struct ServerRecognitionNotice: View {
    let onContinue: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Speech is processed by Apple").font(.title2.bold()).multilineTextAlignment(.center)
                Text("This device can't recognize speech on its own, so while you give a command your voice is sent to Apple to turn it into text, under Apple's privacy policy.")
                    .multilineTextAlignment(.center)
                Text("Open Remote never stores or shares your voice. Only the resulting command is sent — to your TV, on your network.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    Button(action: onContinue) { Text("Continue").frame(maxWidth: 280) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Not Now", action: onDecline)
                }
                .padding(.top, 6)
            }
            .padding(Theme.spacing * 1.5)
            .padding(.top, 24)
        }
    }
}

// MARK: - Examples

enum VoiceExamples {
    static let sections: [(String, String, [String])] = [
        ("Volume", "speaker.wave.2", ["Volume up by 5", "Set volume to 12", "Mute", "Unmute"]),
        ("Channels", "list.number", ["Channel 7", "Go to channel twelve", "Next channel"]),
        ("Apps & inputs", "square.grid.2x2", ["Open Netflix", "Launch YouTube", "Switch to HDMI 2", "Switch to PlayStation"]),
        ("Navigate", "dpad", ["Go home", "Back", "Down three times", "OK", "Open settings"]),
        ("Playback", "playpause", ["Pause", "Play", "Fast forward", "Rewind"]),
        ("Search & type", "magnifyingglass", ["Search YouTube for cooking videos", "Search for nature documentaries", "Type The Office"]),
        ("TV", "tv", ["Turn off the screen", "Sleep in 30 minutes", "Cancel the sleep timer", "Turn off the TV"]),
    ]
    static let suggestions = ["Open Netflix", "Volume up by 5", "Switch to HDMI 2", "Pause", "Search YouTube for cats", "Go home", "Channel 7"]
}

private struct VoiceExamplesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(VoiceExamples.sections, id: \.0) { title, symbol, examples in
                    Section {
                        ForEach(examples, id: \.self) { Text("“\($0)”") }
                    } header: {
                        Label(title, systemImage: symbol)
                    }
                }
                Section {
                    Text("You can add “please”, start with “Hey TV”, and say numbers as words or digits. Commands are in English for now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Things to Say")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// SF Symbol shown next to a confirmation.
enum VoiceSymbols {
    static func symbol(for intent: VoiceIntent?) -> String {
        switch intent {
        case .volumeUp: "speaker.plus"
        case .volumeDown: "speaker.minus"
        case .setVolume: "speaker.wave.2"
        case .mute: "speaker.slash"
        case .unmute: "speaker.wave.2"
        case .channelUp, .channelDown, .channel: "list.number"
        case .openApp: "square.grid.2x2"
        case .switchInput: "cable.connector"
        case .key: "dpad"
        case .media(let c):
            switch c {
            case .play: "play.fill"
            case .pause: "pause.fill"
            case .stop: "stop.fill"
            case .rewind: "backward.fill"
            case .fastForward: "forward.fill"
            }
        case .screenOff: "tv.slash"
        case .screenOn: "tv"
        case .powerOff, .powerOn: "power"
        case .sleepTimer, .cancelSleepTimer: "moon.zzz"
        case .type: "keyboard"
        case .search: "magnifyingglass"
        case .unknown, .none: "checkmark.circle"
        }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        VoiceCommandView().environment(TVSession.preview())
    }
}
