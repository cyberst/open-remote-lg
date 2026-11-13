import Foundation

/// A TV the user has found or saved. Persisted by `DeviceStoring`.
public struct TVDevice: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier. Prefer the TV's UPnP UUID / AirPlay deviceid; fall back to "host:<ip>".
    public var id: String
    public var name: String
    /// Current IP address / hostname. Updated when rediscovered at a new address.
    public var host: String
    /// MAC addresses (wired + wifi) used for Wake-on-LAN.
    public var macAddresses: [String]
    public var modelName: String?
    public var webOSVersion: String?
    /// nil = auto (try 3001/wss then 3000/ws). Remembered after first success.
    public var useSecureSocket: Bool?
    public var lastConnected: Date?
    /// Marks simulator/test fixtures and legacy demo records; never a user-selectable TV.
    public var isDemo: Bool

    public init(id: String, name: String, host: String, macAddresses: [String] = [], modelName: String? = nil,
                webOSVersion: String? = nil, useSecureSocket: Bool? = nil, lastConnected: Date? = nil, isDemo: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.macAddresses = macAddresses; self.modelName = modelName
        self.webOSVersion = webOSVersion; self.useSecureSocket = useSecureSocket; self.lastConnected = lastConnected; self.isDemo = isDemo
    }

    public static let demo = TVDevice(id: "demo", name: "Demo TV", host: "demo.local", modelName: "Demo (no TV needed)", webOSVersion: "Demo", isDemo: true)
}

public enum PairingRequest: Sendable, Hashable {
    /// The TV shows an Accept/Deny prompt; user must press Accept with the physical remote.
    case acceptOnTV
    /// The TV shows a PIN; user must type it in the app and the client calls `submitPairingPIN`.
    case enterPIN
}

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case pairing(PairingRequest)
    case connected
    /// Lost the connection and is retrying automatically (attempt number).
    case reconnecting(attempt: Int)
    case failed(String)

    public var isConnected: Bool { self == .connected }
}

/// Button names understood by the webOS pointer input socket (`type:button\nname:<NAME>\n\n`).
public enum RemoteKey: String, CaseIterable, Sendable, Codable {
    case home = "HOME", back = "BACK", exit = "EXIT", menu = "MENU", qMenu = "QMENU", info = "INFO"
    case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", enter = "ENTER"
    case volumeUp = "VOLUMEUP", volumeDown = "VOLUMEDOWN", mute = "MUTE"
    case channelUp = "CHANNELUP", channelDown = "CHANNELDOWN"
    case red = "RED", green = "GREEN", yellow = "YELLOW", blue = "BLUE"
    case play = "PLAY", pause = "PAUSE", stop = "STOP", rewind = "REWIND", fastForward = "FASTFORWARD", record = "RECORD"
    case num0 = "0", num1 = "1", num2 = "2", num3 = "3", num4 = "4", num5 = "5", num6 = "6", num7 = "7", num8 = "8", num9 = "9"
    case dash = "DASH", asterisk = "ASTERISK", list = "LIST", guide = "GUIDE", flashback = "FLASHBACK"
    case cc = "CC", sap = "SAP", aspectRatio = "ASPECT_RATIO", screenRemote = "SCREEN_REMOTE", liveZoom = "LIVE_ZOOM"
    case teletext = "TELETEXT", textOption = "TEXTOPTION", magnifierZoom = "MAGNIFIER_ZOOM", threeD = "3D_MODE"
    case program = "PROGRAM", favorites = "FAVORITES", search = "SEARCH", inputHub = "INPUT_HUB", eManual = "MANUAL"
    case power = "POWER", myApps = "MYAPPS", recent = "RECENT", amazon = "AMAZON", netflix = "NETFLIX"
}

public enum MediaControl: String, Sendable, CaseIterable {
    case play, pause, stop, rewind, fastForward
}

public struct VolumeState: Sendable, Hashable {
    public var volume: Int
    public var muted: Bool
    /// e.g. "mastervolume_tv_speaker"; external audio devices may not report absolute volume.
    public var scenario: String?
    public init(volume: Int, muted: Bool, scenario: String? = nil) { self.volume = volume; self.muted = muted; self.scenario = scenario }
}

public struct TVApp: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var iconURL: URL?
    public init(id: String, title: String, iconURL: URL? = nil) { self.id = id; self.title = title; self.iconURL = iconURL }
}

public struct TVInput: Sendable, Hashable, Identifiable {
    public var id: String         // e.g. "HDMI_1"
    public var label: String      // e.g. "HDMI 1" or user-renamed label
    public var appId: String?     // e.g. "com.webos.app.hdmi1"
    public var connected: Bool
    public var iconURL: URL?
    public init(id: String, label: String, appId: String? = nil, connected: Bool = false, iconURL: URL? = nil) {
        self.id = id; self.label = label; self.appId = appId; self.connected = connected; self.iconURL = iconURL
    }
}

public struct TVChannel: Sendable, Hashable, Identifiable {
    public var id: String
    public var number: String
    public var name: String
    public init(id: String, number: String, name: String) { self.id = id; self.number = number; self.name = name }
}

public struct TVInfo: Sendable, Hashable {
    public var modelName: String?
    public var webOSVersion: String?
    public var firmwareVersion: String?
    public var macAddresses: [String]
    public var extra: [String: String]
    /// The TV's user-visible name (Settings › General › Devices › TV Name / "Device Name"), e.g. "Living room".
    public var deviceName: String?
    public init(modelName: String? = nil, webOSVersion: String? = nil, firmwareVersion: String? = nil, macAddresses: [String] = [], extra: [String: String] = [:], deviceName: String? = nil) {
        self.modelName = modelName; self.webOSVersion = webOSVersion; self.firmwareVersion = firmwareVersion; self.macAddresses = macAddresses; self.extra = extra
        self.deviceName = deviceName
    }
}

/// State of the TV's on-screen keyboard (IME) for live text sync.
public struct KeyboardState: Sendable, Hashable {
    public var visible: Bool
    public var currentText: String?
    public init(visible: Bool, currentText: String? = nil) { self.visible = visible; self.currentText = currentText }
}

public enum LGError: Error, Sendable, Hashable, LocalizedError {
    case notConnected
    case notImplemented(String)
    case pairingRejected
    case timeout
    case unsupported(String)
    case tvError(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a TV."
        case .notImplemented(let f): "\(f) is not implemented yet."
        case .pairingRejected: "Pairing was declined on the TV."
        case .timeout: "The TV did not respond in time."
        case .unsupported(let f): "This TV does not support \(f)."
        case .tvError(let m): "TV error: \(m)"
        case .network(let m): "Network error: \(m)"
        }
    }
}
