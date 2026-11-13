import Foundation

/// English command rules. Rules run in priority order; the first match wins.
struct EnglishVoiceGrammar: VoiceGrammar {
    func intent(for input: [VoiceToken]) -> VoiceIntent? {
        let tokens = Self.stripFillers(EnglishNumbers.collapse(input))
        guard !tokens.isEmpty else { return nil }
        let c = Command(tokens: tokens)

        // Free-text commands first: their payload may contain any other keyword ("type turn off").
        if let i = typeIntent(c) { return i }
        if let i = searchIntent(c) { return i }

        for rule in [sleepIntent, screenIntent, muteIntent, volumeIntent, powerIntent, channelIntent,
                     inputIntent, mediaIntent, navigationIntent, openIntent] {
            if let i = rule(c) { return i }
        }
        return nil
    }

    // MARK: - Fillers

    private static let leadingFillers: [[String]] = [
        ["hey", "tv"], ["hey", "television"], ["hey", "remote"], ["hey"], ["hi"], ["hello"],
        ["ok", "tv"], ["okay", "tv"], ["ok"], ["okay"], ["alright"], ["all", "right"], ["so"], ["um"], ["uh"], ["erm"],
        ["please"], ["kindly"], ["just"], ["now"], ["and"], ["then"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["can", "u"], ["would", "you", "please"],
        ["i", "want", "you", "to"], ["i", "need", "you", "to"], ["i", "want", "to"], ["i", "wanna"], ["i'd", "like", "to"],
        ["i", "would", "like", "to"], ["let's"], ["lets"], ["go", "ahead", "and"], ["tv"], ["television"],
    ]
    private static let trailingFillers: [[String]] = [
        ["please"], ["for", "me"], ["right", "now"], ["now"], ["thanks"], ["thank", "you"], ["thank", "u"],
    ]

    /// Removes politeness and wake words at either end. Never removes everything ("ok" alone means select).
    static func stripFillers(_ tokens: [VoiceToken]) -> [VoiceToken] {
        var t = tokens[...]
        var changed = true
        while changed {
            changed = false
            for f in leadingFillers where t.count > f.count && t.prefix(f.count).map(\.word) == f {
                t = t.dropFirst(f.count); changed = true; break
            }
            for f in trailingFillers where t.count > f.count && t.suffix(f.count).map(\.word) == f {
                t = t.dropLast(f.count); changed = true; break
            }
        }
        return Array(t)
    }

    // MARK: - Command view

    /// Convenience views over the tokens of one command.
    struct Command {
        let tokens: [VoiceToken]
        let words: [String]
        /// Words without articles/pronouns/"tv" — for matching fixed phrases ("turn the tv off" → "turn off").
        let core: [String]
        var coreText: String { core.joined(separator: " ") }

        static let noise: Set<String> = ["the", "a", "an", "my", "tv", "television", "it", "this", "that", "please", "set", "of"]

        init(tokens: [VoiceToken]) {
            self.tokens = tokens
            words = tokens.map(\.word)
            core = words.filter { !Self.noise.contains($0) }
        }

        func has(_ w: String) -> Bool { words.contains(w) }
        func hasAny(_ ws: Set<String>) -> Bool { words.contains(where: ws.contains) }
        func hasPhrase(_ phrase: String) -> Bool { index(of: phrase.split(separator: " ").map(String.init)) != nil }

        func index(of phrase: [String], in list: [String]? = nil) -> Int? {
            let list = list ?? words
            guard !phrase.isEmpty, list.count >= phrase.count else { return nil }
            for i in 0...(list.count - phrase.count) where Array(list[i..<(i + phrase.count)]) == phrase { return i }
            return nil
        }

        /// If the command starts with one of `prefixes`, returns the tokens after it.
        func after(prefixes: [String]) -> ArraySlice<VoiceToken>? {
            for p in prefixes {
                let ws = p.split(separator: " ").map(String.init)
                if words.count >= ws.count, Array(words.prefix(ws.count)) == ws { return tokens.dropFirst(ws.count) }
            }
            return nil
        }

        var numbers: [Int] { words.compactMap { w in w.allSatisfy(\.isNumber) ? Int(w) : nil } }
        var firstNumber: Int? { numbers.first }
    }

    // MARK: - Type & search

    private func typeIntent(_ c: Command) -> VoiceIntent? {
        guard let rest = c.after(prefixes: ["type in", "type out", "type", "write", "enter text", "input text", "text"]) else { return nil }
        let text = VoiceTokenizer.rawText(rest)
        return text.isEmpty ? nil : .type(text)
    }

    private static let searchApps: [String: String] = ["youtube": "youtube", "netflix": "netflix", "prime": "prime video",
                                                       "amazon": "prime video", "disney": "disney plus", "google": "browser",
                                                       "browser": "browser", "web": "browser", "internet": "browser"]

    private func searchIntent(_ c: Command) -> VoiceIntent? {
        // "search youtube for cats", "search on youtube for cats"
        for (key, app) in Self.searchApps {
            for p in ["search \(key) for", "search on \(key) for", "search in \(key) for", "\(key) search for", "\(key) search",
                      "search \(key)", "find on \(key)", "look up on \(key)"] {
                if let rest = c.after(prefixes: [p]) { return .search(Self.trimQuery(rest), app: app) }
            }
        }
        let prefixes = ["search for", "search", "find me", "find", "look up", "look for", "show me videos of", "show me videos about",
                        "show me videos", "videos of", "videos about"]
        if let rest = c.after(prefixes: prefixes) {
            let (query, app) = Self.splitTrailingApp(rest)
            if c.after(prefixes: ["show me videos", "videos"]) != nil { return .search(query, app: app ?? "youtube") }
            return .search(query, app: app)
        }
        // "play lofi music on youtube"
        if let rest = c.after(prefixes: ["play", "watch", "put on"]) {
            let (query, app) = Self.splitTrailingApp(rest)
            if let app, !query.isEmpty { return .search(query, app: app) }
        }
        return nil
    }

    /// "cats on youtube" → ("cats", "youtube").
    private static func splitTrailingApp(_ rest: ArraySlice<VoiceToken>) -> (String, String?) {
        let words = rest.map(\.word)
        if words.count >= 2, ["on", "in", "using", "with"].contains(words[words.count - 2]),
           let app = searchApps[words[words.count - 1]] {
            return (trimQuery(rest.dropLast(2)), app)
        }
        if words.count >= 3, ["on", "in"].contains(words[words.count - 3]), words[words.count - 1] == "video" || words[words.count - 1] == "plus",
           let app = searchApps[words[words.count - 2]] {
            return (trimQuery(rest.dropLast(3)), app)
        }
        return (trimQuery(rest), nil)
    }

    private static func trimQuery(_ rest: ArraySlice<VoiceToken>) -> String {
        var r = rest
        while let f = r.first, ["for", "about"].contains(f.word), r.count > 1 { r = r.dropFirst() }
        return VoiceTokenizer.rawText(r)
    }

    // MARK: - Sleep timer

    private func sleepIntent(_ c: Command) -> VoiceIntent? {
        let mentionsTimer = c.hasAny(["sleep", "timer"])
        if mentionsTimer {
            let cancel: Set<String> = ["cancel", "stop", "off", "disable", "clear", "remove", "delete", "reset", "kill", "no"]
            if c.hasAny(cancel), Self.duration(c.words) == nil { return .cancelSleepTimer }
            if c.hasPhrase("don't turn off") || c.hasPhrase("do not turn off") { return .cancelSleepTimer }
            if let m = Self.duration(c.words) ?? c.firstNumber, m > 0 { return .sleepTimer(minutes: m) }
            return nil
        }
        // "turn off in 30 minutes", "turn the tv off after an hour"
        let offWords: Set<String> = ["off", "shutdown"]
        if (c.hasAny(offWords) || c.hasPhrase("shut down") || c.hasPhrase("power down")), c.hasAny(["in", "after"]),
           let m = Self.duration(c.words), m > 0 {
            return .sleepTimer(minutes: m)
        }
        return nil
    }

    /// Minutes in phrases like "30 minutes", "an hour", "half an hour", "1 and a half hours", "2 hours 15 minutes".
    static func duration(_ w: [String]) -> Int? {
        let hourWords: Set<String> = ["hour", "hours", "hr", "hrs", "h"]
        let minuteWords: Set<String> = ["minute", "minutes", "min", "mins", "m"]
        var total = 0.0
        var found = false
        for (i, word) in w.enumerated() {
            let isHour = hourWords.contains(word), isMinute = minuteWords.contains(word)
            guard isHour || isMinute else { continue }
            let unit = isHour ? 60.0 : 1.0
            var amount: Double?
            if i >= 1, let n = Double(w[i - 1]) { amount = n }
            if i >= 4, w[i - 3] == "and", w[i - 2] == "a", w[i - 1] == "half", let n = Double(w[i - 4]) { amount = n + 0.5 }
            if i >= 2, w[i - 2] == "half", ["an", "a"].contains(w[i - 1]) { amount = 0.5 }
            if amount == nil, i >= 2, w[i - 2] == "a", w[i - 1] == "half" { amount = 0.5 }
            if amount == nil, i >= 1, ["an", "a", "one"].contains(w[i - 1]) { amount = 1 }
            // "an hour and a half"
            if i + 3 < w.count, w[i + 1] == "and", w[i + 2] == "a", w[i + 3] == "half" { amount = (amount ?? 1) + 0.5 }
            if let amount { total += amount * unit; found = true }
        }
        guard found else { return nil }
        return Int(total.rounded())
    }

    // MARK: - Screen & power

    private func screenIntent(_ c: Command) -> VoiceIntent? {
        guard c.hasAny(["screen", "picture", "display"]), !c.has("remote") else { return nil }
        if c.hasAny(["off", "blank", "dark", "black", "disable"]) { return .screenOff }
        if c.hasAny(["on", "wake", "enable", "back"]) { return .screenOn }
        return nil
    }

    private static let powerOffPhrases: Set<String> = [
        "turn off", "switch off", "power off", "shut off", "shut down", "shutdown", "power down", "off", "good night", "goodnight", "go to sleep", "standby", "go to standby",
    ]
    private static let powerOnPhrases: Set<String> = ["turn on", "switch on", "power on", "on", "wake up", "wake"]

    private func powerIntent(_ c: Command) -> VoiceIntent? {
        // "turn the power off" → "turn off"
        let core = c.coreText.replacingOccurrences(of: " power ", with: " ")
        if Self.powerOffPhrases.contains(core) { return .powerOff }
        if Self.powerOnPhrases.contains(core) { return .powerOn }
        return nil
    }

    // MARK: - Volume

    private func muteIntent(_ c: Command) -> VoiceIntent? {
        let core = c.coreText
        let unmute: Set<String> = ["unmute", "un mute", "sound on", "turn on sound", "turn sound on", "turn sound back on",
                                   "turn on audio", "audio on", "restore sound", "bring back sound", "unmute sound",
                                   "turn off mute", "turn mute off", "mute off", "stop muting", "cancel mute"]
        if unmute.contains(core) || c.has("unmute") || c.has("unmuted") { return .unmute }
        let mute: Set<String> = ["mute", "silence", "sound off", "turn off sound", "turn sound off", "audio off", "be quiet",
                                 "quiet", "shut up", "mute sound", "mute audio", "turn on mute", "turn mute on", "mute on", "hush"]
        if mute.contains(core) || (c.has("mute") && c.words.count <= 4) { return .mute }
        return nil
    }

    private static let upWords: Set<String> = ["up", "increase", "raise", "louder", "higher", "boost", "more", "plus"]
    private static let downWords: Set<String> = ["down", "decrease", "lower", "quieter", "softer", "reduce", "less", "minus"]

    private func volumeIntent(_ c: Command) -> VoiceIntent? {
        let mentionsVolume = c.hasAny(["volume", "sound", "audio", "loudness"])
        let core = c.core
        let isUp = c.hasAny(Self.upWords), isDown = c.hasAny(Self.downWords)
        let implicitVolume = c.hasAny(["louder", "quieter", "softer"])
            || core.starts(with: ["turn", "up"]) || core.starts(with: ["turn", "down"])
        guard mentionsVolume || implicitVolume else { return nil }

        // "volume to 10", "turn the volume down to 5"
        if mentionsVolume, let i = c.words.firstIndex(where: { $0 == "to" || $0 == "at" }), i + 1 < c.words.count,
           let n = Int(c.words[i + 1]) {
            return .setVolume(max(0, min(100, n)))
        }
        if isUp != isDown {
            var amount = 1
            if c.hasPhrase("a lot") || c.has("much") { amount = 10 }
            if c.hasPhrase("a little") || c.hasPhrase("a bit") || c.has("slightly") { amount = 1 }
            if let n = c.firstNumber { amount = n }
            amount = max(1, min(100, amount))
            return isUp ? .volumeUp(by: amount) : .volumeDown(by: amount)
        }
        if mentionsVolume, let n = c.firstNumber { return .setVolume(max(0, min(100, n))) }
        return nil
    }

    // MARK: - Channels

    private func channelIntent(_ c: Command) -> VoiceIntent? {
        guard let idx = c.words.firstIndex(where: { $0 == "channel" || $0 == "channels" || $0 == "ch" }) else { return nil }
        let before = Set(c.words[..<idx])
        var rest = Array(c.words[(idx + 1)...])
        let upWords: Set<String> = ["up", "next", "plus", "forward", "higher"]
        let downWords: Set<String> = ["down", "previous", "prev", "minus", "lower", "back", "backward"]
        if rest.isEmpty || upWords.contains(rest[0]) || downWords.contains(rest[0]) {
            let all = before.union(rest.prefix(1))
            if !all.isDisjoint(with: upWords) { return .channelUp }
            if !all.isDisjoint(with: downWords) { return .channelDown }
            return nil
        }
        while let f = rest.first, ["to", "number", "no", "on", "the", "#"].contains(f) { rest.removeFirst() }
        guard !rest.isEmpty else { return nil }
        // Numbers: "12", "5-1", "5 dash 1", "5 point 1", "1 2" (spoken digit by digit).
        var number = ""
        var isNumber = true
        for w in rest {
            if w.allSatisfy({ $0.isNumber || $0 == "-" }) { number += w }
            else if ["dash", "point", "dot", "hyphen"].contains(w), !number.isEmpty, !number.hasSuffix("-") { number += "-" }
            else { isNumber = false; break }
        }
        if isNumber, !number.isEmpty, number.first?.isNumber == true, number.last?.isNumber == true { return .channel(number) }
        let trailing: Set<String> = ["please", "now", "on", "tv"]
        while let l = rest.last, trailing.contains(l), rest.count > 1 { rest.removeLast() }
        return .channel(rest.joined(separator: " "))
    }

    // MARK: - Inputs

    private static let homophoneDigits: [String: Int] = ["to": 2, "too": 2, "for": 4, "won": 1, "free": 3, "tree": 3]

    private func inputIntent(_ c: Command) -> VoiceIntent? {
        let w = c.words
        // "hdmi 2", "hdmi2", "hdmi two", "hdmi port 2"
        for (i, word) in w.enumerated() {
            if word.hasPrefix("hdmi") {
                let tail = word.dropFirst(4).filter(\.isNumber)
                if let n = Int(String(tail)), n > 0 { return .switchInput(.hdmi(n)) }
                var j = i + 1
                if j < w.count, w[j] == "port" || w[j] == "input" { j += 1 }
                if j < w.count, let n = Int(w[j]) ?? Self.homophoneDigits[w[j]], n > 0 { return .switchInput(.hdmi(n)) }
                return .switchInput(.named("hdmi"))
            }
        }
        // "switch input to playstation", "change the source to xbox", "input 2", "source av"
        guard let idx = w.firstIndex(where: { ["input", "inputs", "source", "sources"].contains($0) }) else { return nil }
        var rest = Array(w[(idx + 1)...])
        while let f = rest.first, ["to", "the", "of", "number"].contains(f) { rest.removeFirst() }
        guard !rest.isEmpty else { return nil }
        if rest.count == 1, let n = Int(rest[0]), n > 0 { return .switchInput(.hdmi(n)) }
        return .switchInput(.named(rest.joined(separator: " ")))
    }

    // MARK: - Playback

    private func mediaIntent(_ c: Command) -> VoiceIntent? {
        var core = c.core
        if let f = core.first, ["press", "hit", "push", "tap"].contains(f) { core.removeFirst() }
        if let l = core.last, ["button", "key"].contains(l) { core.removeLast() }
        let text = core.joined(separator: " ")
        let table: [String: MediaControl] = [
            "play": .play, "resume": .play, "continue": .play, "unpause": .play, "resume playback": .play, "start playing": .play,
            "keep playing": .play, "continue playing": .play, "play video": .play, "play again": .play,
            "pause": .pause, "pause video": .pause, "pause playback": .pause, "hold on": .pause, "wait": .pause, "pause movie": .pause,
            "stop": .stop, "stop playback": .stop, "stop video": .stop, "stop playing": .stop, "stop movie": .stop,
            "rewind": .rewind, "go backwards": .rewind, "skip back": .rewind, "skip backward": .rewind, "skip backwards": .rewind,
            "rewind video": .rewind, "backwards": .rewind,
            "fast forward": .fastForward, "fastforward": .fastForward, "forward": .fastForward, "skip ahead": .fastForward,
            "skip forward": .fastForward, "ff": .fastForward, "go forward": .fastForward, "fast-forward": .fastForward,
        ]
        return table[text].map { .media($0) }
    }

    // MARK: - Navigation

    private func navigationIntent(_ c: Command) -> VoiceIntent? {
        var core = c.core
        if let f = core.first, ["press", "hit", "push", "tap", "click"].contains(f), core.count > 1 { core.removeFirst() }
        if let l = core.last, ["button", "key", "arrow"].contains(l), core.count > 1 { core.removeLast() }
        let text = core.joined(separator: " ")
        let fixed: [String: RemoteKey] = [
            "home": .home, "go home": .home, "home screen": .home, "go to home": .home, "go to home screen": .home, "main screen": .home,
            "back": .back, "go back": .back, "return": .back, "previous screen": .back, "back up": .back,
            "ok": .enter, "okay": .enter, "select": .enter, "enter": .enter, "confirm": .enter, "click": .enter, "choose": .enter,
            "select this": .enter, "open this": .enter, "yes": .enter,
            "exit": .exit, "quit": .exit, "close": .exit, "close app": .exit, "exit app": .exit, "leave": .exit,
            "settings": .menu, "menu": .menu, "open settings": .menu, "show settings": .menu, "go to settings": .menu,
            "open menu": .menu, "show menu": .menu, "settings menu": .menu,
            "quick settings": .qMenu, "open quick settings": .qMenu, "show quick settings": .qMenu,
            "info": .info, "information": .info, "show info": .info, "show information": .info, "details": .info,
            "guide": .guide, "program guide": .guide, "show guide": .guide, "open guide": .guide, "epg": .guide,
            "red": .red, "green": .green, "yellow": .yellow, "blue": .blue,
        ]
        if let key = fixed[text] { return .key(key) }

        // Directions with an optional count: "down", "move left 3", "go right three times", "up twice".
        let directions: [String: RemoteKey] = ["up": .up, "down": .down, "left": .left, "right": .right]
        var words = core
        if let f = words.first, ["move", "go", "scroll", "arrow", "navigate", "press", "cursor"].contains(f), words.count > 1 { words.removeFirst() }
        guard let first = words.first, let key = directions[first] else { return nil }
        let rest = Array(words.dropFirst())
        var times = 1
        switch rest {
        case []: break
        case ["once"]: times = 1
        case ["twice"]: times = 2
        case ["thrice"]: times = 3
        case let r where r.count <= 2 && Int(r[0]) != nil && (r.count == 1 || ["times", "time", "steps", "step", "x"].contains(r[1])):
            times = Int(r[0]) ?? 1
        case let r where r.count == 1 && ["one", "two", "to", "too"].contains(r[0]):
            times = r[0] == "one" ? 1 : 2
        default: return nil
        }
        return .key(key, times: max(1, min(times, 20)))
    }

    // MARK: - Apps

    private func openIntent(_ c: Command) -> VoiceIntent? {
        let verbs = ["open up", "open", "launch", "start up", "start", "run", "load", "fire up", "bring up", "go to", "go into",
                     "switch to", "switch over to", "change to", "put on", "show me", "show", "watch", "turn on", "go"]
        guard var rest = c.after(prefixes: verbs).map(Array.init) else { return nil }
        let leading: Set<String> = ["the", "my", "up", "to", "app"]
        let trailing: Set<String> = ["app", "application", "apps", "please", "now", "on", "the", "tv", "television"]
        while let f = rest.first, leading.contains(f.word), rest.count > 1 { rest.removeFirst() }
        while rest.count > 1, let l = rest.last, trailing.contains(l.word) {
            // keep "apple tv" / "live tv"
            if l.word == "tv", ["apple", "live", "pluto", "samsung"].contains(rest[rest.count - 2].word) { break }
            rest.removeLast()
        }
        let name = rest.map(\.word).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        switch name {
        case "home", "home screen": return .key(.home)
        case "settings", "setting", "menu": return .key(.menu)
        case "quick settings": return .key(.qMenu)
        case "guide", "program guide", "tv guide": return .key(.guide)
        default: return .openApp(name)
        }
    }
}
