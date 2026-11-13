import Foundation
import Network

/// What a discovery source learned about a host before it is verified.
struct DiscoveryHints: Sendable, Equatable {
    var upnpUUID: String?
    var location: String?
    var airPlayName: String?
    var homeKitName: String?
    var airPlayDeviceID: String?
    var model: String?
    var macAddresses: [String] = []
    /// Advertised itself as an LG TV over Bonjour.
    var isLGBonjour = false

    mutating func merge(_ o: DiscoveryHints) {
        upnpUUID = upnpUUID ?? o.upnpUUID
        location = location ?? o.location
        airPlayName = airPlayName ?? o.airPlayName
        homeKitName = homeKitName ?? o.homeKitName
        airPlayDeviceID = airPlayDeviceID ?? o.airPlayDeviceID
        model = model ?? o.model
        for mac in o.macAddresses where !macAddresses.contains(mac) { macAddresses.append(mac) }
        isLGBonjour = isLGBonjour || o.isLGBonjour
    }
}

/// Bonjour services LG webOS TVs advertise. Verified on a 2019 LG 55SM8000PLA (webOS 4.5):
///  * `_airplay._tcp` — instance "[LG] webOS TV SM8000PLA", TXT manufacturer=LG Electronics, model=55SM8000PLA,
///    deviceid=<AirPlay id, not the network MAC>, serialNumber=<serial>_<wired MAC>
///  * `_hap._tcp` (HomeKit) — instance "LG webOS TV 6D11", TXT md=WEBOS
/// 2014–2018 TVs advertise neither (no AirPlay/HomeKit); they are found by SSDP or the subnet sweep instead.
/// Every type browsed here must be listed in `NSBonjourServices` in Config/Info.plist.
enum BonjourTV {
    static let serviceTypes = ["_airplay._tcp", "_hap._tcp"]

    /// Hints for an LG TV, or nil when the advertisement isn't from an LG webOS TV.
    static func hints(serviceType: String, name: String, txt: [String: String]) -> DiscoveryHints? {
        let lowerTXT = Dictionary(txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var h = DiscoveryHints()
        switch serviceType.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
        case "_airplay._tcp":
            let manufacturer = lowerTXT["manufacturer"]?.lowercased() ?? ""
            guard manufacturer.hasPrefix("lg") || name.hasPrefix("[LG]") else { return nil }
            h.airPlayName = name
            h.model = lowerTXT["model"].flatMap { $0.isEmpty ? nil : $0 }
            h.airPlayDeviceID = lowerTXT["deviceid"].flatMap(MACAddress.normalized)
            if let serial = lowerTXT["serialnumber"], let mac = MACAddress.firstMAC(in: serial) { h.macAddresses = [mac] }
        case "_hap._tcp":
            guard lowerTXT["md"]?.lowercased() == "webos" || name.localizedCaseInsensitiveContains("webOS TV") else { return nil }
            h.homeKitName = name
        default:
            return nil
        }
        h.isLGBonjour = true
        return h
    }
}

/// Browses `BonjourTV.serviceTypes` with `NWBrowser` and resolves LG TVs to IPv4.
final class BonjourBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.simber.openremoteforlg.bonjour")
    private var browsers: [NWBrowser] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handled: Set<String> = []
    private var stopped = false

    func start(onFound: @escaping @Sendable (UInt32, DiscoveryHints) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            for type in BonjourTV.serviceTypes {
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
                browser.browseResultsChangedHandler = { [weak self] _, changes in
                    for change in changes {
                        switch change {
                        case .added(let result), .changed(_, let result, _): self?.handle(result, onFound: onFound)
                        default: break
                        }
                    }
                }
                browser.stateUpdateHandler = { state in
                    if case .failed = state { browser.cancel() }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            browsers.forEach { $0.cancel() }
            browsers = []
            connections.values.forEach { $0.cancel() }
            connections = [:]
        }
    }

    /// Runs on `queue`.
    private func handle(_ result: NWBrowser.Result, onFound: @escaping @Sendable (UInt32, DiscoveryHints) -> Void) {
        guard !stopped, case .service(let name, let type, _, _) = result.endpoint else { return }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        guard let hints = BonjourTV.hints(serviceType: type, name: name, txt: txt) else { return }
        let key = "\(type)|\(name)"
        guard handled.insert(key).inserted else { return }

        // Resolve by connecting over IPv4 and reading the remote address; the connection is dropped immediately.
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: result.endpoint, using: params)
        let connectionID = ObjectIdentifier(connection)
        connections[connectionID] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let addr) = host {
                    let b = [UInt8](addr.rawValue)
                    if b.count == 4 {
                        onFound(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]), hints)
                    }
                }
                connection.cancel()
            case .waiting, .failed:
                connection.cancel()
                self.handled.remove(key) // allow a retry if the service is re-announced
            case .cancelled:
                self.connections[connectionID] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak connection] in connection?.cancel() }
    }
}
