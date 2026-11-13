import Foundation

/// Fuzzy matching of spoken names against the TV's app titles, input labels and channel names.
public enum VoiceNameMatcher {
    /// A well-known app with the names people say for it and the ids it ships under.
    public struct Alias: Sendable, Hashable {
        public let displayName: String
        public let spokenNames: [String]
        /// Lowercased substrings of webOS app ids that identify the app.
        public let idFragments: [String]
        /// Id used when the TV's app list is unavailable.
        public let defaultID: String?
    }

    public static let aliases: [Alias] = [
        Alias(displayName: "YouTube", spokenNames: ["youtube", "you tube", "yt", "youtubes"], idFragments: ["youtube.leanback", "youtube"], defaultID: "youtube.leanback.v4"),
        Alias(displayName: "Netflix", spokenNames: ["netflix", "net flix", "netflicks"], idFragments: ["netflix"], defaultID: "netflix"),
        Alias(displayName: "Prime Video", spokenNames: ["prime", "prime video", "amazon", "amazon prime", "amazon prime video", "amazon video"],
              idFragments: ["amazon", "primevideo"], defaultID: "amazon"),
        Alias(displayName: "Disney+", spokenNames: ["disney", "disney plus", "disneyplus", "disney channel plus"], idFragments: ["disney"], defaultID: "com.disney.disneyplus-prod"),
        Alias(displayName: "Apple TV", spokenNames: ["apple tv", "apple tv plus", "apple", "appletv"], idFragments: ["com.apple.appletv"], defaultID: "com.apple.appletv"),
        Alias(displayName: "Spotify", spokenNames: ["spotify", "spot ify"], idFragments: ["spotify"], defaultID: "spotify-beehive"),
        Alias(displayName: "Live TV", spokenNames: ["live tv", "tv", "live", "antenna", "cable", "broadcast", "television", "live television", "tv channels"],
              idFragments: ["com.webos.app.livetv"], defaultID: "com.webos.app.livetv"),
        Alias(displayName: "Web Browser", spokenNames: ["browser", "web browser", "internet", "web", "internet browser", "the internet"],
              idFragments: ["com.webos.app.browser"], defaultID: "com.webos.app.browser"),
        Alias(displayName: "Photo & Video", spokenNames: ["photos", "photo and video", "photo", "pictures", "gallery", "videos"],
              idFragments: ["com.webos.app.photovideo"], defaultID: nil),
        Alias(displayName: "Music", spokenNames: ["music", "music player"], idFragments: ["com.webos.app.music"], defaultID: nil),
        Alias(displayName: "LG Content Store", spokenNames: ["store", "app store", "content store", "lg content store", "lg store"],
              idFragments: ["com.webos.app.discovery"], defaultID: nil),
        Alias(displayName: "Hulu", spokenNames: ["hulu"], idFragments: ["hulu"], defaultID: nil),
        Alias(displayName: "Max", spokenNames: ["max", "hbo", "hbo max"], idFragments: ["hbo", "com.wbd"], defaultID: nil),
        Alias(displayName: "Plex", spokenNames: ["plex"], idFragments: ["plex"], defaultID: nil),
        Alias(displayName: "Twitch", spokenNames: ["twitch"], idFragments: ["twitch"], defaultID: nil),
    ]

    public static func alias(for spoken: String) -> Alias? {
        let n = normalize(spoken)
        return aliases.first { $0.spokenNames.contains(n) || $0.spokenNames.map(compact).contains(compact(n)) }
    }

    /// Lowercase words with punctuation removed and number words as digits ("Disney+" → "disney plus", "BBC One" → "bbc 1").
    public static func normalize(_ s: String) -> String {
        EnglishNumbers.collapse(VoiceTokenizer.tokenize(s)).map(\.word).joined(separator: " ")
    }

    static func compact(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "") }

    /// 0…1 confidence that `spoken` refers to `title`.
    public static func score(_ spoken: String, _ title: String) -> Double {
        let a = normalize(spoken), b = normalize(title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let ca = compact(a), cb = compact(b)
        if ca == cb { return 0.97 }
        let bw = b.split(separator: " ").map(String.init), aw = a.split(separator: " ").map(String.init)
        if bw.starts(with: aw) { return 0.92 }
        if containsWords(bw, aw) { return 0.85 }
        if cb.count >= 3, containsWords(aw, bw) { return 0.8 }
        let sim = similarity(ca, cb)
        if sim >= 0.75 { return sim * 0.9 }
        // Prefix of a long title: "photo" → "Photo & Video" handled above; "amazon" → "Amazon Prime Video".
        if ca.count >= 4, cb.hasPrefix(ca) { return 0.78 }
        return sim * 0.5
    }

    private static func containsWords(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }

    /// Normalised Levenshtein similarity.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = prev
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    static let threshold = 0.75

    /// The installed app the user most likely meant, using well-known aliases first.
    public static func bestApp(for spoken: String, in apps: [TVApp]) -> TVApp? {
        if let alias = alias(for: spoken) {
            if let id = alias.defaultID, let exact = apps.first(where: { $0.id == id }) { return exact }
            for fragment in alias.idFragments {
                if let app = apps.first(where: { $0.id.lowercased().contains(fragment) }) { return app }
            }
        }
        return best(spoken, apps, \.title)
    }

    public static func bestInput(for spoken: String, in inputs: [TVInput]) -> TVInput? {
        best(spoken, inputs, \.label)
    }

    public static func hdmiInput(_ n: Int, in inputs: [TVInput]) -> TVInput? {
        inputs.first { $0.id.uppercased() == "HDMI_\(n)" }
            ?? inputs.first { ($0.appId ?? "").lowercased().hasSuffix("hdmi\(n)") }
            ?? inputs.first { normalize($0.label) == "hdmi \(n)" }
    }

    public static func bestChannel(for spoken: String, in channels: [TVChannel]) -> TVChannel? {
        let target = canonicalChannelNumber(spoken)
        if target.first?.isNumber == true {
            return channels.first { canonicalChannelNumber($0.number) == target }
        }
        return best(spoken, channels, \.name)
    }

    /// "05.1" / "5-1" → "5-1"; "012" → "12".
    static func canonicalChannelNumber(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == " " })
        guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return normalize(s) }
        return parts.map { String(Int($0) ?? 0) }.joined(separator: "-")
    }

    private static func best<T>(_ spoken: String, _ items: [T], _ name: KeyPath<T, String>) -> T? {
        var bestItem: T?
        var bestScore = threshold
        for item in items {
            let s = score(spoken, item[keyPath: name])
            if s > bestScore || (bestItem == nil && s >= bestScore) { bestItem = item; bestScore = s }
        }
        return bestItem
    }
}
