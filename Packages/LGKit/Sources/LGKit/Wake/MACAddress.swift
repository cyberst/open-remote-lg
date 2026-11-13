import Foundation

/// MAC address parsing shared by Wake-on-LAN, discovery and device merging.
public enum MACAddress {
    /// Parses "aa:bb:cc:dd:ee:ff", "AA-BB-CC-DD-EE-FF", "aabbccddeeff", "aabb.ccdd.eeff" and
    /// zero-stripped groups like "0:1b:2:3d:4e:5f". Returns 6 bytes or nil.
    public static func bytes(_ string: String) -> [UInt8]? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = s.split(whereSeparator: { $0 == ":" || $0 == "-" })
        let hexPairs: [Substring]
        if groups.count == 6 {
            guard groups.allSatisfy({ (1...2).contains($0.count) }) else { return nil }
            hexPairs = groups
        } else {
            let compact = s.filter { $0 != "." && $0 != ":" && $0 != "-" }
            guard compact.count == 12 else { return nil }
            var pairs: [Substring] = []
            var i = compact.startIndex
            while i < compact.endIndex {
                let j = compact.index(i, offsetBy: 2)
                pairs.append(compact[i..<j]); i = j
            }
            hexPairs = pairs
        }
        var out: [UInt8] = []
        for pair in hexPairs {
            guard pair.allSatisfy(\.isHexDigit), let b = UInt8(pair, radix: 16) else { return nil }
            out.append(b)
        }
        return out.count == 6 ? out : nil
    }

    /// Canonical form "aa:bb:cc:dd:ee:ff" (lower-case), or nil if unparsable.
    public static func normalized(_ string: String) -> String? {
        bytes(string).map { $0.map { String(format: "%02x", $0) }.joined(separator: ":") }
    }

    /// False for all-zero, broadcast and multicast addresses, which never identify a TV.
    public static func isUsable(_ string: String) -> Bool {
        guard let b = bytes(string) else { return false }
        return !b.allSatisfy({ $0 == 0 }) && !b.allSatisfy({ $0 == 0xFF }) && b[0] & 0x01 == 0
    }

    /// The first colon/dash separated MAC inside free text (e.g. an AirPlay `serialNumber`), normalized.
    static func firstMAC(in text: String) -> String? {
        let pattern = "[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(\\1[0-9A-Fa-f]{2}){4}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return normalized(String(text[range])).flatMap { isUsable($0) ? $0 : nil }
    }
}
