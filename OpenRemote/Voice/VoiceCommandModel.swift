import SwiftUI
import LGKit

/// Drives the voice sheet: permissions → listening → executing → result.
@MainActor
@Observable
final class VoiceCommandModel {
    enum Phase: Equatable {
        case idle
        /// Server-based recognition will be used; explain before the first use.
        case consent
        case listening
        case working
        case done(String)
        case failed(String)
        case denied(SpeechRecognizer.Permission)
    }

    private(set) var phase: Phase = .idle
    /// The command that was heard (final), shown after listening ends.
    private(set) var heard = ""
    private(set) var lastIntent: VoiceIntent?

    let speech = SpeechRecognizer()
    private let parser: VoiceCommandParser
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var touchDownWhileListening = false

    static let consentKey = "voice.serverRecognitionAccepted"
    private var consentGiven: Bool {
        get { UserDefaults.standard.bool(forKey: Self.consentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.consentKey) }
    }

    init() {
        parser = VoiceCommandParser(locale: speech.locale)
        refreshPermission()
    }

    /// Re-checks permissions (e.g. after returning from Settings).
    func refreshPermission() {
        #if DEBUG
        if debugStateForced { return }
        #endif
        let p = SpeechRecognizer.currentPermission
        if p != .granted && p != .notDetermined {
            if phase != .listening { phase = .denied(p) }
        } else if case .denied = phase {
            phase = .idle
        }
    }

    var isListening: Bool { phase == .listening }
    var needsServerConsent: Bool { !speech.supportsOnDevice && !consentGiven }
    /// Text to show in the transcript area.
    var displayedTranscript: String {
        guard phase == .listening else { return heard }
        #if DEBUG
        if let t = speechDebugTranscript { return t }
        #endif
        return speech.transcript
    }

    // MARK: - Mic button

    /// Finger down on the mic. Starts listening unless already listening (then the tap will stop it).
    func pressBegan(session: TVSession) {
        touchDownWhileListening = isListening
        if !isListening { start(session: session) }
    }

    /// Finger up. A long hold ends the command (push-to-talk); a short tap keeps listening until a pause.
    func pressEnded(heldFor seconds: TimeInterval) {
        if touchDownWhileListening || seconds >= 0.5 { speech.stop() }
        touchDownWhileListening = false
    }

    func toggle(session: TVSession) {
        if isListening { speech.stop() } else { start(session: session) }
    }

    func start(session: TVSession) {
        guard listenTask == nil else { return }
        if needsServerConsent { phase = .consent; return }
        listenTask = Task { [weak self] in
            await self?.listen(session: session)
            self?.listenTask = nil
        }
    }

    func acceptServerRecognition(session: TVSession) {
        consentGiven = true
        phase = .idle
        start(session: session)
    }

    func declineServerRecognition() { phase = .idle }

    func cancel() {
        speech.cancel()
        listenTask?.cancel()
        listenTask = nil
        if phase == .listening { phase = .idle }
    }

    private func listen(session: TVSession) async {
        var permission = SpeechRecognizer.currentPermission
        if permission == .notDetermined { permission = await SpeechRecognizer.requestPermission() }
        guard permission == .granted else { phase = .denied(permission); Haptics.error(); return }
        guard !Task.isCancelled else { return }

        if speech.contextualStrings.isEmpty {
            let titles = (try? await session.run { try await $0.apps() })?.map(\.title) ?? []
            speech.contextualStrings = titles + ["HDMI", "Netflix", "YouTube", "Prime Video", "Disney Plus", "Apple TV", "Spotify", "Live TV"]
        }

        heard = ""
        phase = .listening
        Haptics.press()
        do {
            let text = try await speech.listen()
            await execute(text, session: session)
        } catch is CancellationError {
            if phase == .listening { phase = .idle }
        } catch {
            phase = .failed(error.localizedDescription)
            Haptics.error()
        }
    }

    // MARK: - Execution

    /// Parses and runs `transcript` against the current TV.
    func execute(_ transcript: String, session: TVSession) async {
        heard = transcript
        let intent = parser.parse(transcript)
        lastIntent = intent
        if case .unknown = intent {
            phase = .failed(VoiceCommandError.notUnderstood(transcript).localizedDescription)
            Haptics.error()
            return
        }
        phase = .working
        do {
            let message = try await session.run { tv in try await VoiceCommandExecutor(tv: tv).execute(intent) }
            phase = .done(message)
            Haptics.success()
            AccessibilityNotification.Announcement(message).post()
        } catch {
            phase = .failed(error.localizedDescription)
            Haptics.error()
            AccessibilityNotification.Announcement(error.localizedDescription).post()
        }
    }

    // MARK: - Debug states for screenshots

    #if DEBUG
    /// `-VoiceDebugState listening|done|failed|consent|denied|working` forces a state for UI review.
    func applyDebugState(_ state: String) {
        debugStateForced = true
        switch state {
        case "listening": heard = ""; phase = .listening; speechDebugTranscript = "open net"
        case "working": heard = "Open Netflix"; phase = .working
        case "done": heard = "Volume up by five"; lastIntent = .volumeUp(by: 5); phase = .done("Volume 17")
        case "failed": heard = "What's the weather like"; phase = .failed(VoiceCommandError.notUnderstood("What's the weather like").localizedDescription)
        case "consent": phase = .consent
        case "denied": phase = .denied(.deniedMicrophone)
        default: break
        }
    }
    var speechDebugTranscript: String?
    @ObservationIgnored private var debugStateForced = false
    #endif
}
