import Foundation

public enum VoiceCommandError: Error, LocalizedError, Hashable, Sendable {
    case notUnderstood(String)
    case appNotFound(String)
    case appNotInstalled(String)
    case inputNotFound(String)
    case channelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notUnderstood(let t): t.isEmpty ? "I didn't hear a command." : "Sorry, I didn't understand “\(t)”."
        case .appNotFound(let n): "Couldn't find “\(n)” on this TV."
        case .appNotInstalled(let n): "\(n) isn't installed on this TV."
        case .inputNotFound(let n): "Couldn't find the input “\(n)”."
        case .channelNotFound(let n): "Couldn't find channel \(n)."
        }
    }
}

/// Runs a `VoiceIntent` against a TV and returns a short confirmation such as "Volume 12" or "Opening Netflix".
public actor VoiceCommandExecutor {
    private let tv: any TVControlling
    private var appsCache: (date: Date, apps: [TVApp])?
    /// Pause between repeated key presses ("down 3 times") so the TV registers each one.
    private let repeatDelay: Duration

    public init(tv: any TVControlling, repeatDelay: Duration = .milliseconds(150)) {
        self.tv = tv
        self.repeatDelay = repeatDelay
    }

    /// Parses and executes a transcript.
    public func run(_ transcript: String, parser: VoiceCommandParser = VoiceCommandParser()) async throws -> (VoiceIntent, String) {
        let intent = parser.parse(transcript)
        return (intent, try await execute(intent))
    }

    public func execute(_ intent: VoiceIntent) async throws -> String {
        switch intent {
        case .volumeUp(let n): return try await changeVolume(by: max(1, n))
        case .volumeDown(let n): return try await changeVolume(by: -max(1, n))
        case .setVolume(let v):
            let value = Self.clampVolume(v)
            try await tv.setVolume(value)
            return "Volume \(value)"
        case .mute:
            try await tv.setMute(true)
            return "Muted"
        case .unmute:
            try await tv.setMute(false)
            return "Sound on"

        case .channelUp:
            try await tv.channelUp()
            return "Channel up"
        case .channelDown:
            try await tv.channelDown()
            return "Channel down"
        case .channel(let q): return try await tuneChannel(q)

        case .openApp(let name): return try await open(name)
        case .switchInput(let target): return try await switchInput(target)

        case .key(let key, let times):
            let count = max(1, min(times, 20))
            for i in 0..<count {
                if i > 0 { try? await Task.sleep(for: repeatDelay) }
                try await tv.press(key)
            }
            return count > 1 ? "\(Self.keyName(key)) × \(count)" : Self.keyName(key)

        case .media(let control):
            try await tv.media(control)
            switch control {
            case .play: return "Playing"
            case .pause: return "Paused"
            case .stop: return "Stopped"
            case .rewind: return "Rewinding"
            case .fastForward: return "Fast-forwarding"
            }

        case .screenOff:
            try await tv.screenOff()
            return "Screen off"
        case .screenOn:
            try await tv.screenOn()
            return "Screen on"
        case .powerOff:
            try await tv.powerOff()
            return "Turning off the TV"
        case .powerOn:
            // A connected TV is already on; make sure the picture is too.
            try? await tv.screenOn()
            return "The TV is on"
        case .sleepTimer(let minutes):
            try await tv.setSleepTimer(minutes: max(1, minutes))
            return "Sleep timer: \(Self.formatMinutes(max(1, minutes)))"
        case .cancelSleepTimer:
            try await tv.setSleepTimer(minutes: nil)
            return "Sleep timer off"

        case .type(let text):
            try await tv.insertText(text, replace: false)
            return "Typed “\(text)”"
        case .search(let query, let app): return try await search(query, app: app)

        case .unknown(let t): throw VoiceCommandError.notUnderstood(t)
        }
    }

    // MARK: - Volume

    static func clampVolume(_ v: Int) -> Int { max(0, min(100, v)) }

    private func changeVolume(by delta: Int) async throws -> String {
        let before = try? await tv.volume()
        if abs(delta) == 1 {
            if delta > 0 { try await tv.volumeUp() } else { try await tv.volumeDown() }
            if let before { return "Volume \(Self.clampVolume(before.volume + delta))" }
            return delta > 0 ? "Volume up" : "Volume down"
        }
        if let before {
            let target = Self.clampVolume(before.volume + delta)
            try await tv.setVolume(target)
            return "Volume \(target)"
        }
        // Absolute volume unknown (e.g. external speakers): step instead.
        for i in 0..<min(abs(delta), 20) {
            if i > 0 { try? await Task.sleep(for: repeatDelay) }
            if delta > 0 { try await tv.volumeUp() } else { try await tv.volumeDown() }
        }
        return delta > 0 ? "Volume up \(abs(delta))" : "Volume down \(abs(delta))"
    }

    // MARK: - Channels

    private func tuneChannel(_ query: String) async throws -> String {
        let channels = (try? await tv.channels()) ?? []
        if let ch = VoiceNameMatcher.bestChannel(for: query, in: channels) {
            try await tv.setChannel(id: ch.id)
            let named = ch.name.isEmpty || ch.name == "Channel \(ch.number)" ? "" : " · \(ch.name)"
            return "Channel \(ch.number)\(named)"
        }
        let number = VoiceNameMatcher.canonicalChannelNumber(query)
        guard number.first?.isNumber == true, number.allSatisfy({ $0.isNumber || $0 == "-" }) else {
            throw VoiceCommandError.channelNotFound(query)
        }
        // No channel list (or not found in it): type the number like a physical remote would.
        if (try? await tv.foregroundAppID()) != "com.webos.app.livetv" {
            try await tv.launchApp(id: "com.webos.app.livetv", params: nil)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        for ch in number {
            if ch == "-" { try await tv.press(.dash) } else if let key = RemoteKey(rawValue: String(ch)) { try await tv.press(key) }
        }
        try await tv.press(.enter)
        return "Channel \(number)"
    }

    // MARK: - Apps & inputs

    private func installedApps() async throws -> [TVApp] {
        if let cache = appsCache, Date().timeIntervalSince(cache.date) < 60 { return cache.apps }
        let apps = try await tv.apps()
        appsCache = (Date(), apps)
        return apps
    }

    private func open(_ name: String) async throws -> String {
        let alias = VoiceNameMatcher.alias(for: name)
        let apps: [TVApp]
        do { apps = try await installedApps() } catch {
            // App list unavailable: launch well-known apps by their usual id.
            guard let alias, let id = alias.defaultID else { throw error }
            try await tv.launchApp(id: id, params: nil)
            return "Opening \(alias.displayName)"
        }
        let inputs = (try? await tv.inputs()) ?? []
        let app = VoiceNameMatcher.bestApp(for: name, in: apps)
        let input = VoiceNameMatcher.bestInput(for: name, in: inputs)
        // Prefer an input only when it matches better than the app ("PlayStation" input vs a "PlayStation Plus" app).
        let appScore = app.map { alias != nil ? 0.99 : VoiceNameMatcher.score(name, $0.title) } ?? 0
        if let input, VoiceNameMatcher.score(name, input.label) > appScore {
            try await tv.switchInput(id: input.id)
            return "Switching to \(input.label)"
        }
        if let app {
            try await tv.launchApp(id: app.id, params: nil)
            return "Opening \(app.title)"
        }
        if let alias { throw VoiceCommandError.appNotInstalled(alias.displayName) }
        throw VoiceCommandError.appNotFound(Self.displayName(name))
    }

    private func switchInput(_ target: InputTarget) async throws -> String {
        let inputs: [TVInput]
        do { inputs = try await tv.inputs() } catch {
            guard case .hdmi(let n) = target else { throw error }
            try await tv.switchInput(id: "HDMI_\(n)")
            return "Switching to HDMI \(n)"
        }
        switch target {
        case .hdmi(let n):
            guard let input = VoiceNameMatcher.hdmiInput(n, in: inputs) else { throw VoiceCommandError.inputNotFound("HDMI \(n)") }
            try await tv.switchInput(id: input.id)
            let label = VoiceNameMatcher.normalize(input.label) == "hdmi \(n)" ? "HDMI \(n)" : "HDMI \(n) · \(input.label)"
            return "Switching to \(label)"
        case .named(let name):
            if let input = VoiceNameMatcher.bestInput(for: name, in: inputs) {
                try await tv.switchInput(id: input.id)
                return "Switching to \(input.label)"
            }
            if name == "hdmi", let first = inputs.first(where: { $0.id.uppercased().hasPrefix("HDMI") && $0.connected })
                ?? inputs.first(where: { $0.id.uppercased().hasPrefix("HDMI") }) {
                try await tv.switchInput(id: first.id)
                return "Switching to \(first.label)"
            }
            // "switch input to netflix" — fall back to apps.
            if let app = VoiceNameMatcher.bestApp(for: name, in: (try? await installedApps()) ?? []) {
                try await tv.launchApp(id: app.id, params: nil)
                return "Opening \(app.title)"
            }
            throw VoiceCommandError.inputNotFound(Self.displayName(name))
        }
    }

    // MARK: - Search

    /// Launch parameters that open YouTube's TV app on a search for `query`. The leanback app accepts a
    /// youtube.com/tv deep link in `contentTarget`; `launch=voice&vq=` is its voice-search entry point.
    public static func youTubeSearchParams(_ query: String) -> JSON {
        var c = URLComponents(string: "https://www.youtube.com/tv")
        c?.queryItems = [URLQueryItem(name: "launch", value: "voice"), URLQueryItem(name: "vq", value: query)]
        return ["contentTarget": .string(c?.url?.absoluteString ?? "https://www.youtube.com/tv")]
    }

    /// Web search used when YouTube is not installed. DuckDuckGo, in keeping with the app's no-tracking stance.
    public static func webSearchURL(_ query: String) -> URL? {
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }

    private func search(_ query: String, app: String?) async throws -> String {
        if query.isEmpty {
            try await tv.press(.search)
            return "Opening search"
        }
        // A text field is focused on the TV: type the query there.
        if app == nil, let kb = await currentKeyboard(), kb.visible {
            try await tv.insertText(query, replace: true)
            try await tv.sendEnter()
            return "Searching for “\(query)”"
        }
        let apps = try? await installedApps()
        let wantsYouTube = app == nil || app == "youtube"
        if wantsYouTube {
            let youTube: TVApp? = apps.map { VoiceNameMatcher.bestApp(for: "youtube", in: $0) }
                ?? TVApp(id: "youtube.leanback.v4", title: "YouTube")
            if let youTube {
                try await tv.launchApp(id: youTube.id, params: Self.youTubeSearchParams(query))
                return "Searching YouTube for “\(query)”"
            }
            if app == "youtube" { throw VoiceCommandError.appNotInstalled("YouTube") }
        } else if let app, app != "browser" {
            guard let target = VoiceNameMatcher.bestApp(for: app, in: apps ?? []) else {
                throw VoiceCommandError.appNotInstalled(VoiceNameMatcher.alias(for: app)?.displayName ?? Self.displayName(app))
            }
            // Most TV apps take no search deep link; open the app so the user can continue there.
            try await tv.launchApp(id: target.id, params: nil)
            return "Opening \(target.title)"
        }
        guard let url = Self.webSearchURL(query) else { throw VoiceCommandError.notUnderstood(query) }
        try await tv.openURLInBrowser(url)
        return "Searching the web for “\(query)”"
    }

    /// First keyboard state from the TV, or nil if it doesn't answer quickly.
    private func currentKeyboard() async -> KeyboardState? {
        let stream = tv.observeKeyboard()
        return await withTaskGroup(of: KeyboardState?.self) { group in
            group.addTask { for await k in stream { return k }; return nil }
            group.addTask { try? await Task.sleep(for: .milliseconds(400)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Formatting

    static func keyName(_ key: RemoteKey) -> String {
        switch key {
        case .home: "Home"
        case .back: "Back"
        case .enter: "OK"
        case .exit: "Exit"
        case .menu: "Settings"
        case .qMenu: "Quick Settings"
        case .info: "Info"
        case .guide: "Guide"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .red: "Red button"
        case .green: "Green button"
        case .yellow: "Yellow button"
        case .blue: "Blue button"
        case .search: "Search"
        default: key.rawValue.capitalized
        }
    }

    static func formatMinutes(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(m) min" }
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func displayName(_ spoken: String) -> String {
        spoken.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
