import Foundation
import LGKit

/// The model year of an LG TV, read from its model name with LG's model-year codes. Used to open
/// "Select a remote" on the remote that shipped with the TV.
///
///   55**SM**8000, 43**UK**6300, 50**UQ**7500  → the second letter after the size (M = 2019, K = 2018, Q = 2022)
///   OLED65**C9**PUA, OLED55**CX**, OLED65**G1** → the character after the series letter (9 = 2019, X = 2020, 1 = 2021)
///   65NANO90**UP**A, 65QNED85**T6**A           → the letter after the series number (P = 2021, T = 2024)
///
/// The webOS version only breaks ties (OLED "6" is 2016 or 2026) or stands in when the model name says nothing.
enum TVModelYear {
    /// Year letters used by LCD/LED (UHD, NanoCell, QNED) model names.
    static let letterYears: [Character: Int] = [
        "B": 2014, "F": 2015, "H": 2016, "J": 2017, "K": 2018, "M": 2019,
        "N": 2020, "P": 2021, "Q": 2022, "R": 2023, "T": 2024, "A": 2025,
    ]

    /// Year characters used by OLED model names (OLED<size><series><year>…).
    static let oledYears: [Character: Int] = [
        "6": 2016, "7": 2017, "8": 2018, "9": 2019, "X": 2020,
        "1": 2021, "2": 2022, "3": 2023, "4": 2024, "5": 2025,
    ]

    static func year(modelName: String?, webOSVersion: String? = nil) -> Int? {
        let webOSYear = year(webOSVersion: webOSVersion)
        if let modelName {
            // Model names can come wrapped, e.g. "[LG] webOS TV OLED55C9PLA" or "55SM8600PLA.AEU".
            let tokens = modelName.uppercased().split { !$0.isLetter && !$0.isNumber }
            for token in tokens {
                if let y = year(token: Substring(token), webOSYear: webOSYear) { return y }
            }
        }
        return webOSYear
    }

    /// Release year implied by a webOS version: 1 → 2014 … 6.0 → 2021, then 22 → 2022 and so on.
    /// Approximate for 2022+ TVs, which can update to newer webOS releases.
    static func year(webOSVersion: String?) -> Int? {
        guard let raw = webOSVersion?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1].prefix(1)) ?? 0 : 0
        switch major {
        case 1: return 2014
        case 2: return 2015
        case 3: return minor >= 5 ? 2017 : 2016
        case 4: return minor >= 5 ? 2019 : 2018
        case 5: return 2020
        case 6: return 2021
        case 22...99: return 2000 + major
        default: return nil
        }
    }

    private static func year(token: Substring, webOSYear: Int?) -> Int? {
        if token.hasPrefix("OLED") { return oledYear(token.dropFirst(4), webOSYear: webOSYear) }

        let size = token.prefix(while: \.isNumber)
        guard (2...3).contains(size.count) else { return nil }
        let rest = token.dropFirst(size.count)

        if rest.hasPrefix("NANO") || rest.hasPrefix("QNED") {
            // <size>NANO|QNED<series number><letters>: 65NANO90UPA, 50NANO75UQA, 65NANO86TNA, 65QNED85T6A, 65QNED85AUA
            let suffix = Array(rest.dropFirst(4).drop(while: \.isNumber))
            guard suffix.count >= 2 else { return nil }
            return letterYears[suffix[1]] ?? letterYears[suffix[0]]
        }

        // <size><panel letter><year letter><series number>: 55SM8000, 43UK6300, 49LF6300, 55UR8000
        let chars = Array(rest)
        guard chars.count >= 3, chars[0].isLetter, chars[2].isNumber else { return nil }
        return letterYears[chars[1]]
    }

    private static func oledYear(_ rest: Substring, webOSYear: Int?) -> Int? {
        // OLED<size><series letter><year>…: OLED65C9PUA, OLED55CX, OLED77Z29LA, OLED65B6P
        let afterSize = Array(rest.drop(while: \.isNumber))
        guard afterSize.count >= 2, afterSize[0].isLetter, let y = oledYears[afterSize[1]] else { return nil }
        guard y == 2016 else { return y }
        // "6" means 2016 or 2026. The webOS version settles it; otherwise 2016 names were short (OLED65C6P, OLED55B6V).
        if let webOSYear { return webOSYear >= 2022 ? 2026 : 2016 }
        return afterSize.count <= 3 ? 2016 : 2026
    }
}

extension TVModelYear {
    /// Model year of a saved TV (nil for the Demo TV or unknown models; the remote picker then opens on its default).
    static func year(for device: TVDevice?) -> Int? {
        guard let device, !device.isDemo else { return nil }
        return year(modelName: device.modelName, webOSVersion: device.webOSVersion)
    }
}
