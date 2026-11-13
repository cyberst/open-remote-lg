import Foundation

/// English number words → digits ("twenty five" → 25, "one hundred and five" → 105).
enum EnglishNumbers {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || w == "hundred"
    }

    private enum Kind { case unit, teen, ten, hundred, and }

    /// Replaces runs of number words with a single digits token. Runs that cannot form one number
    /// ("five one") become separate numbers, which callers such as channel parsing may concatenate.
    static func collapse(_ tokens: [VoiceToken]) -> [VoiceToken] {
        var out: [VoiceToken] = []
        var i = 0
        while i < tokens.count {
            if let (value, length) = number(in: tokens, at: i) {
                let raw = tokens[i..<(i + length)].map(\.raw).filter { !$0.isEmpty }.joined(separator: " ")
                out.append(VoiceToken(word: String(value), raw: raw))
                i += length
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    /// Parses the longest number starting at `start`. Returns nil if `tokens[start]` does not begin a number word.
    private static func number(in tokens: [VoiceToken], at start: Int) -> (Int, Int)? {
        var j = start
        var current = 0
        var last: Kind?
        // "a hundred"
        if tokens[j].word == "a", j + 1 < tokens.count, tokens[j + 1].word == "hundred" {
            current = 1; last = .unit; j += 1
        }
        var consumedEnd = start // exclusive end of the last token that completed a valid number
        while j < tokens.count {
            let w = tokens[j].word
            if let u = units[w] {
                guard last == nil || last == .hundred || last == .and || (last == .ten && current % 10 == 0) else { break }
                current += u; last = .unit
            } else if let t = teens[w] {
                guard last == nil || last == .hundred || last == .and else { break }
                current += t; last = .teen
            } else if let t = tens[w] {
                guard last == nil || last == .hundred || last == .and else { break }
                current += t; last = .ten
            } else if w == "hundred" {
                guard last == nil || ((last == .unit || last == .teen) && current < 100) else { break }
                current = max(current, 1) * 100; last = .hundred
            } else if w == "and", last == .hundred, j + 1 < tokens.count,
                      units[tokens[j + 1].word] != nil || teens[tokens[j + 1].word] != nil || tens[tokens[j + 1].word] != nil {
                last = .and
                j += 1
                continue
            } else {
                break
            }
            j += 1
            consumedEnd = j
        }
        guard consumedEnd > start else { return nil }
        return (current, consumedEnd - start)
    }
}
