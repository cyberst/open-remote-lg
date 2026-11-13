import Foundation

/// Reconciles freshly discovered TVs with saved ones so a TV that changed IP keeps its saved identity
/// (and therefore its pairing key, which is stored per device id).
public enum TVDeviceMerge {
    /// Name used when the TV gave us nothing better.
    public static func fallbackName(host: String) -> String { "LG TV (\(host))" }

    /// Same physical TV? Matches on id, on any shared usable MAC address, or — when either side only has a
    /// host-based id (`host:<ip>`) — on the host itself. The demo TV only matches itself.
    public static func isSameTV(_ a: TVDevice, _ b: TVDevice) -> Bool {
        if a.isDemo || b.isDemo { return a.isDemo && b.isDemo && a.id == b.id }
        if a.id == b.id { return true }
        let macsA = Set(a.macAddresses.filter(MACAddress.isUsable).compactMap(MACAddress.normalized))
        if !macsA.isEmpty, !macsA.isDisjoint(with: b.macAddresses.filter(MACAddress.isUsable).compactMap(MACAddress.normalized)) {
            return true
        }
        if a.id.hasPrefix("host:") || b.id.hasPrefix("host:") {
            return a.host.caseInsensitiveCompare(b.host) == .orderedSame
        }
        return false
    }

    /// Index of the saved device that is the same TV as `discovered` (exact id match wins).
    public static func indexOfMatch(for discovered: TVDevice, in saved: [TVDevice]) -> Int? {
        saved.firstIndex { $0.id == discovered.id } ?? saved.firstIndex { isSameTV($0, discovered) }
    }

    /// `saved` refreshed from `discovered`: new host, union of MACs, model/version filled in if missing, and the
    /// discovered name if the saved one was only a placeholder. Keeps id, secure-socket choice and lastConnected.
    public static func updated(_ saved: TVDevice, with discovered: TVDevice) -> TVDevice {
        var d = saved
        d.host = discovered.host
        var seen = Set(d.macAddresses.compactMap(MACAddress.normalized))
        for mac in discovered.macAddresses {
            guard let n = MACAddress.normalized(mac), seen.insert(n).inserted else { continue }
            d.macAddresses.append(mac)
        }
        if d.modelName?.isEmpty ?? true { d.modelName = discovered.modelName }
        if d.webOSVersion?.isEmpty ?? true { d.webOSVersion = discovered.webOSVersion }
        if d.name.isEmpty || d.name.hasPrefix("LG TV (") { d.name = discovered.name }
        return d
    }

    /// Merges `discovered` into `saved`, preserving saved order. Matched devices are updated in place
    /// (see `updated(_:with:)`); unmatched ones are appended only when `appendNew` is true.
    public static func merge(_ discovered: [TVDevice], into saved: [TVDevice], appendNew: Bool = false) -> [TVDevice] {
        var result = saved
        for device in discovered where !device.isDemo {
            if let i = indexOfMatch(for: device, in: result) {
                result[i] = updated(result[i], with: device)
            } else if appendNew {
                result.append(device)
            }
        }
        return result
    }
}
