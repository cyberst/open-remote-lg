import Foundation

/// Pure functions turning SSAP payloads into models. Payload shapes differ between webOS generations, so every
/// parser accepts all known variants and never traps on unexpected data.
enum SSAPParsers {

    // MARK: Audio

    /// webOS 1–4: `{volume, muted, scenario}`.
    /// webOS 5+: `{volumeStatus: {volume, muteStatus, soundOutput, ...}}` (subscriptions too).
    static func volume(_ p: JSON) -> VolumeState? {
        let status = p["volumeStatus"] ?? p
        guard let volume = status["volume"]?.intValue ?? p["volume"]?.intValue else { return nil }
        let muted = status["muteStatus"]?.boolValue ?? status["muted"]?.boolValue ?? status["mute"]?.boolValue
            ?? p["muted"]?.boolValue ?? p["mute"]?.boolValue ?? false
        let scenario = p["scenario"]?.stringValue ?? status["soundOutput"]?.stringValue ?? status["scenario"]?.stringValue
        return VolumeState(volume: volume, muted: muted, scenario: scenario)
    }

    // MARK: Power

    /// `com.webos.service.tvpower/power/getPowerState`: `{"state":"Active"|"Screen Off"|"Screen Saver"|"Active Standby"|…,
    /// "processing":"Screen Off"|"Screen On"|…}`. True = picture off. Nil while the TV heads to standby, or for an
    /// error / unknown payload.
    static func screenOff(_ p: JSON) -> Bool? {
        switch p["processing"]?.stringValue {
        case "Screen Off": return true
        case "Screen On": return false
        default: break
        }
        switch p["state"]?.stringValue {
        case "Screen Off": return true
        case "Active", "Screen Saver": return false
        default: return nil
        }
    }

    // MARK: Apps

    /// Accepts `listLaunchPoints` (`launchPoints`) and `listApps` (`apps`) payloads. Hidden apps are dropped.
    static func apps(_ p: JSON, host: String) -> [TVApp] {
        let items = p["launchPoints"]?.arrayValue ?? p["apps"]?.arrayValue ?? []
        var seen = Set<String>()
        return items.compactMap { item -> TVApp? in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            if item["visible"]?.boolValue == false || item["hidden"]?.boolValue == true { return nil }
            // listLaunchPoints may list several launch points for one app; keep the first (the default one).
            guard seen.insert(id).inserted else { return nil }
            let title = item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let icon = absoluteURL(item["icon"]?.stringValue, host: host)
                ?? absoluteURL(item["largeIcon"]?.stringValue, host: host)
                ?? absoluteURL(item["mediumIcon"]?.stringValue, host: host)
            return TVApp(id: id, title: title, iconURL: icon)
        }
    }

    // MARK: Inputs

    static func inputs(_ p: JSON, host: String) -> [TVInput] {
        (p["devices"]?.arrayValue ?? p["inputs"]?.arrayValue ?? []).compactMap { d in
            guard let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
            let label = d["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id.replacingOccurrences(of: "_", with: " ")
            let connected = d["connected"]?.boolValue ?? (d["connected"]?.intValue).map { $0 != 0 } ?? false
            return TVInput(id: id, label: label, appId: d["appId"]?.stringValue, connected: connected,
                           iconURL: absoluteURL(d["icon"]?.stringValue, host: host))
        }
    }

    // MARK: Foreground app

    static func foregroundApp(_ p: JSON) -> String? {
        let id = p["appId"]?.stringValue ?? p["foregroundAppInfo"]?[0]?["appId"]?.stringValue
        return id
    }

    // MARK: Channels

    static func channels(_ p: JSON) -> [TVChannel] {
        (p["channelList"]?.arrayValue ?? p["channels"]?.arrayValue ?? []).compactMap(channel)
    }

    static func channel(_ c: JSON) -> TVChannel? {
        guard let id = c["channelId"]?.stringValue ?? c["id"]?.stringValue, !id.isEmpty else { return nil }
        let number = c["channelNumber"]?.stringValue ?? c["channelNumber"]?.intValue.map(String.init)
            ?? c["number"]?.stringValue ?? ""
        let name = c["channelName"]?.stringValue ?? c["name"]?.stringValue ?? number
        return TVChannel(id: id, number: number, name: name)
    }

    // MARK: IME (registerRemoteKeyboard)

    /// webOS 3+: `{currentWidget: {focus, contentType, hiddenText, ...}}`; older firmware: `{focus}` /
    /// `{keyboardVisible}`. Returns nil for messages that carry no keyboard state (e.g. `{subscribed: true}`).
    static func keyboard(_ p: JSON) -> KeyboardState? {
        if let w = p["currentWidget"] {
            let focus = w["focus"]?.boolValue ?? (w["focus"]?.intValue).map { $0 != 0 } ?? false
            return KeyboardState(visible: focus, currentText: w["surroundingText"]?.stringValue)
        }
        if let v = p["keyboardVisible"]?.boolValue ?? p["focus"]?.boolValue ?? p["visible"]?.boolValue {
            return KeyboardState(visible: v, currentText: p["surroundingText"]?.stringValue)
        }
        return nil
    }

    // MARK: System info

    struct SoftwareInfo: Equatable {
        var webOSVersion: String?
        var firmwareVersion: String?
        var extra: [String: String] = [:]
    }

    /// `com.webos.service.update/getCurrentSWInformation` (needs a signed manifest on newer TVs).
    static func softwareInfo(_ p: JSON) -> SoftwareInfo {
        var info = SoftwareInfo()
        if let product = p["product_name"]?.stringValue { // e.g. "webOSTV 4.5", "webOSTV 7.0"
            info.webOSVersion = marketingWebOSVersion(fromProductName: product)
            info.extra["productName"] = product
        }
        if let major = p["major_ver"]?.stringValue, let minor = p["minor_ver"]?.stringValue {
            info.firmwareVersion = "\(major).\(minor)"
        }
        for key in ["model_name", "country", "device_id", "sw_type"] {
            if let v = p[key]?.stringValue, !v.isEmpty { info.extra[key] = v }
        }
        return info
    }

    /// "webOSTV 4.5" → "4.5"; "webOSTV 7.3" → "22" (LG markets webOS 7+ by year: 7=22, 8=23, 9=24, 10=25).
    static func marketingWebOSVersion(fromProductName product: String) -> String? {
        let digits = product.drop(while: { !$0.isNumber })
        guard !digits.isEmpty else { return nil }
        let version = String(digits.prefix(while: { $0.isNumber || $0 == "." }))
        guard let major = Int(version.split(separator: ".").first ?? "") else { return version }
        if (7...20).contains(major) { return String(major + 15) }
        return version
    }

    /// `com.webos.service.connectionmanager/getinfo` → MACs (wired first, then Wi-Fi), upper-cased, de-duplicated.
    static func macAddresses(_ p: JSON) -> [String] {
        var macs: [String] = []
        for key in ["wiredInfo", "wifiInfo"] {
            if let m = p[key]?["macAddress"]?.stringValue?.uppercased(), isValidMAC(m), !macs.contains(m) { macs.append(m) }
        }
        return macs
    }

    static func isValidMAC(_ s: String) -> Bool {
        let parts = s.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) } && s != "00:00:00:00:00:00"
    }

    /// `settings/getSystemSettings {category: network, keys: [deviceName]}` → user-visible TV name.
    static func deviceName(_ p: JSON) -> String? {
        let name = p["settings"]?["deviceName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// Best-effort webOS version from the model name when the TV won't tell us (unsigned manifests cannot read
    /// `getCurrentSWInformation` on many TVs). Uses LG's model-year letter: e.g. 55**SM**8000 → 2019 → webOS 4.5,
    /// OLED55**C9** → 2019, OLED65**C1** → 2021.
    static func estimatedWebOSVersion(modelName: String) -> String? {
        let m = modelName.uppercased()
        let byYear: [Int: String] = [2014: "1", 2015: "2.0", 2016: "3.0", 2017: "3.5", 2018: "4.0", 2019: "4.5",
                                     2020: "5.0", 2021: "6.0", 2022: "22", 2023: "23", 2024: "24", 2025: "25", 2026: "26"]
        var year: Int?
        if m.hasPrefix("OLED") {
            // OLED<size><series letter><year digit|X>
            let rest = m.dropFirst(4).drop(while: \.isNumber)
            if rest.count >= 2 {
                let c = rest[rest.index(after: rest.startIndex)]
                switch c {
                case "6": year = 2016; case "7": year = 2017; case "8": year = 2018; case "9": year = 2019
                case "X": year = 2020; case "1": year = 2021; case "2": year = 2022; case "3": year = 2023
                case "4": year = 2024; case "5": year = 2025
                default: break
                }
            }
        } else {
            // <size><panel letter><year letter>..., e.g. 55SM8000, 43UK6300, 49LF6300, 50UQ7500
            let rest = m.drop(while: \.isNumber)
            if rest.count >= 3, !rest.hasPrefix("NANO"), !rest.hasPrefix("QNED") {
                let c = rest[rest.index(after: rest.startIndex)]
                let letters: [Character: Int] = ["B": 2014, "F": 2015, "H": 2016, "J": 2017, "K": 2018, "M": 2019,
                                                 "N": 2020, "P": 2021, "Q": 2022, "R": 2023, "T": 2024, "A": 2025]
                year = letters[c]
            }
        }
        return year.flatMap { byYear[$0] }
    }

    // MARK: Helpers

    /// Makes TV-relative resource paths absolute. Filesystem paths on the TV (e.g. `/media/cryptofs/...`) are not
    /// served over HTTP and yield nil.
    static func absoluteURL(_ s: String?, host: String) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("/resources/") || s.hasPrefix("resources/") {
            let path = s.hasPrefix("/") ? s : "/" + s
            return URL(string: "http://\(hostForURL(host)):3000\(path)")
        }
        return nil
    }

    /// Wraps IPv6 literals in brackets.
    static func hostForURL(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    /// Message of an SSAP error / failed response.
    static func errorText(_ message: JSON) -> String {
        if let e = message["error"]?.stringValue, !e.isEmpty {
            if let t = message["payload"]?["errorText"]?.stringValue, !t.isEmpty { return "\(e) (\(t))" }
            return e
        }
        return message["payload"]?["errorText"]?.stringValue ?? message["payload"]?["errorMessage"]?.stringValue ?? "Unknown error"
    }
}
