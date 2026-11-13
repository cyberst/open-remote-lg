import AVFoundation
import LGKit
import Speech

enum SpeechError: LocalizedError, Equatable {
    case unavailable
    case noMicrophone
    case noSpeech
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now. Check your internet connection or try again later."
        case .noMicrophone: "No microphone is available."
        case .noSpeech: "I didn't hear anything. Tap the mic and try again."
        case .failed(let m): m
        }
    }
}

/// One-shot speech-to-text for short commands: listens until the speaker pauses, then returns the transcript.
/// Prefers on-device recognition so audio never leaves the device when the hardware supports it.
@MainActor
@Observable
final class SpeechRecognizer {
    enum Permission: Equatable { case notDetermined, granted, deniedMicrophone, deniedSpeech, restricted }

    /// Live (partial) transcript while listening.
    private(set) var transcript = ""
    /// 0…1 input level, for the listening animation.
    private(set) var level: Double = 0
    private(set) var isListening = false

    let locale: Locale
    /// Whether the spoken language matches the device language (false → we fell back to US English).
    let usesDeviceLanguage: Bool
    var contextualStrings: [String] = []

    /// How long a pause ends the command once something has been heard.
    var silenceTimeout: Duration = .milliseconds(1400)
    /// How long to wait for the first word.
    var initialTimeout: Duration = .seconds(7)
    var maxDuration: Duration = .seconds(20)

    @ObservationIgnored private let recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var maxTimer: Task<Void, Never>?
    @ObservationIgnored private var continuation: CheckedContinuation<String, Error>?

    init() {
        let (locale, matches) = Self.chooseLocale()
        self.locale = locale
        self.usesDeviceLanguage = matches
        recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.defaultTaskHint = .search
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }
    /// True when audio is processed on this device only.
    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    /// Device locale when both the recogniser and the command parser support it; otherwise US English.
    static func chooseLocale() -> (Locale, Bool) {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) })
        let candidates = [Locale.current] + Locale.preferredLanguages.map { Locale(identifier: $0) }
        for candidate in candidates where VoiceCommandParser.supports(candidate) {
            if supported.contains(candidate.identifier(.bcp47)) { return (candidate, true) }
            // e.g. "en-TR" isn't a recogniser locale; use the language with its most common region.
            if let lang = candidate.language.languageCode?.identifier,
               let maximal = Locale.Language(identifier: lang).maximalIdentifier.split(separator: "-").last {
                let guess = "\(lang)-\(maximal)"
                if supported.contains(guess) { return (Locale(identifier: guess), true) }
            }
        }
        let deviceIsEnglish = Locale.current.language.languageCode?.identifier == "en"
        return (Locale(identifier: "en-US"), deviceIsEnglish)
    }

    // MARK: - Permissions

    static var currentPermission: Permission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied: return .deniedSpeech
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .authorized: break
        @unknown default: return .notDetermined
        }
        switch AVAudioApplication.shared.recordPermission {
        case .denied: return .deniedMicrophone
        case .undetermined: return .notDetermined
        default: return .granted
        }
    }

    /// Asks for speech recognition, then microphone access. Returns the resulting permission.
    static func requestPermission() async -> Permission {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        switch speech {
        case .denied: return .deniedSpeech
        case .restricted: return .restricted
        case .authorized: break
        default: return .deniedSpeech
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return mic ? .granted : .deniedMicrophone
    }

    // MARK: - Listening

    /// Listens until the speaker pauses (or `stop()`), then returns the final transcript.
    /// Throws `CancellationError` after `cancel()`.
    func listen() async throws -> String {
        guard continuation == nil else { throw SpeechError.failed("Already listening.") }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        transcript = ""
        level = 0

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechError.noMicrophone
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.addsPunctuation = false
        request.contextualStrings = Array(contextualStrings.prefix(100))
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Self.deactivate()
            throw SpeechError.noMicrophone
        }
        Self.installTap(on: input, format: format, request: request) { [weak self] level in
            Task { @MainActor in if self?.isListening == true { self?.level = level } }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            Self.deactivate()
            throw SpeechError.noMicrophone
        }

        self.engine = engine
        self.request = request
        isListening = true

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            task = Self.recognitionTask(recognizer, request) { [weak self] text, isFinal, error in
                Task { @MainActor in self?.handle(text: text, isFinal: isFinal, error: error) }
            }
            restartTimer(initial: true)
            maxTimer = Task { [weak self, maxDuration] in
                try? await Task.sleep(for: maxDuration)
                if !Task.isCancelled { self?.stop() }
            }
        }
    }

    /// Stops recording; the result arrives shortly after through `listen()`.
    func stop() {
        guard isListening else { return }
        isListening = false
        level = 0
        stopAudio()
        request?.endAudio()
        // If the recogniser doesn't deliver a final result promptly, use what we have.
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.finish(self.transcript.isEmpty ? .failure(SpeechError.noSpeech) : .success(self.transcript))
        }
    }

    func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func handle(text: String?, isFinal: Bool, error: Error?) {
        guard continuation != nil else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            if isListening { restartTimer(initial: false) }
        }
        if isFinal {
            finish(transcript.isEmpty ? .failure(SpeechError.noSpeech) : .success(transcript))
        } else if let error {
            if !transcript.isEmpty { finish(.success(transcript)); return }
            let ns = error as NSError
            // kAFAssistantErrorDomain 1110 = no speech detected; 203/216/301 = cancelled/interrupted.
            if ns.domain == "kAFAssistantErrorDomain", [1110, 203, 216, 301].contains(ns.code) {
                finish(.failure(SpeechError.noSpeech))
            } else {
                finish(.failure(SpeechError.failed(error.localizedDescription)))
            }
        }
    }

    private func restartTimer(initial: Bool) {
        timer?.cancel()
        let delay = initial ? initialTimeout : silenceTimeout
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { self?.stop() }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        timer?.cancel(); timer = nil
        maxTimer?.cancel(); maxTimer = nil
        isListening = false
        level = 0
        stopAudio()
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        Self.deactivate()
        let c = continuation
        continuation = nil
        c?.resume(with: result)
    }

    private func stopAudio() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private nonisolated static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // These run their closures on audio / recogniser queues, so they are built outside the main actor.

    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping @Sendable (Double) -> Void) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(n))
            // Map roughly -50 dB…-10 dB to 0…1.
            let db = 20 * log10(max(rms, 1e-6))
            level(Double(max(0, min(1, (db + 50) / 40))))
        }
    }

    private nonisolated static func recognitionTask(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                                    handler: @escaping @Sendable (String?, Bool, Error?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error)
        }
    }
}
