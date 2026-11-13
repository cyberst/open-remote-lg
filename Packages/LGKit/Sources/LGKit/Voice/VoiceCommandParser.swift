import Foundation

/// Turns a speech transcript into a `VoiceIntent`.
///
/// Parsing is split into a language-neutral tokenizer and a per-language `VoiceGrammar`.
/// v1 ships English only; add a grammar and register it in `grammar(for:)` to support another language.
public struct VoiceCommandParser: Sendable {
    /// Language codes (ISO 639-1) that have a grammar.
    public static let supportedLanguageCodes: Set<String> = ["en"]

    private let grammar: any VoiceGrammar

    public init(locale: Locale = Locale(identifier: "en_US")) {
        grammar = Self.grammar(for: locale)
    }

    /// Whether commands spoken in `locale`'s language can be understood.
    public static func supports(_ locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return supportedLanguageCodes.contains(code)
    }

    public func parse(_ transcript: String) -> VoiceIntent {
        let tokens = VoiceTokenizer.tokenize(transcript)
        guard !tokens.isEmpty else { return .unknown(transcript) }
        return grammar.intent(for: tokens) ?? .unknown(transcript)
    }

    private static func grammar(for locale: Locale) -> any VoiceGrammar {
        switch locale.language.languageCode?.identifier {
        default: EnglishVoiceGrammar()
        }
    }
}

/// A language-specific set of rules. Receives tokens with punctuation removed; returns nil when nothing matches.
protocol VoiceGrammar: Sendable {
    func intent(for tokens: [VoiceToken]) -> VoiceIntent?
}

/// One spoken word: `word` is lowercased with punctuation stripped (used for matching); `raw` is the
/// original spelling (used for free text such as "type …"). Number words may be collapsed into digits,
/// in which case `word` is the digits and `raw` keeps the spoken words.
struct VoiceToken: Sendable, Hashable {
    var word: String
    var raw: String
}

enum VoiceTokenizer {
    static func tokenize(_ transcript: String) -> [VoiceToken] {
        var text = transcript
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "%", with: " percent ")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        // Separate trailing punctuation that the recogniser glues onto words ("up," "Netflix.").
        text = text.replacingOccurrences(of: "\n", with: " ")
        var tokens: [VoiceToken] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            let raw = String(piece)
            let word = normalize(raw)
            guard !word.isEmpty else { continue }
            // "twenty-five" → "twenty" "five"; keep "5-1" (channel) and "x-men" intact.
            if word.contains("-"), !word.contains(where: \.isNumber) {
                let parts = word.split(separator: "-").map(String.init)
                if parts.count > 1, parts.allSatisfy({ EnglishNumbers.isNumberWord($0) }) {
                    for (i, p) in parts.enumerated() { tokens.append(VoiceToken(word: p, raw: i == 0 ? raw : "")) }
                    continue
                }
            }
            tokens.append(VoiceToken(word: word, raw: raw))
        }
        return tokens
    }

    /// Lowercases and keeps letters, digits, apostrophes, and in-word "-" / "." (for "5-1", "5.1").
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" || ch == "." { out.append(ch) }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "'-."))
        // "5.1" → "5-1" so channel numbers have one form.
        if out.contains("."), out.allSatisfy({ $0.isNumber || $0 == "." }) { out = out.replacingOccurrences(of: ".", with: "-") }
        return out.replacingOccurrences(of: ".", with: "")
    }

    /// Joins the original spellings, dropping trailing sentence punctuation the recogniser adds.
    static func rawText(_ tokens: some Collection<VoiceToken>) -> String {
        let joined = tokens.map(\.raw).filter { !$0.isEmpty }.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: ").union(.whitespaces))
    }
}
