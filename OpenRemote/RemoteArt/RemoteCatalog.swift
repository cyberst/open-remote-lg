import Foundation
import ImageIO
import LGKit
import UIKit

// The remote picture catalog (redesign v2): `Resources/Remotes/remotes.json` + one lossless WebP per remote, made by the
// image agent. Every key is a normalised rect on the image plus an action from a small text vocabulary. Until the
// real catalog ships, a placeholder catalog rendered from the code-drawn sample remotes is used instead.

// MARK: - Model

/// One remote picture and its key map.
struct RemoteSpec: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    let name: String
    /// Human-readable range shown in accessibility, e.g. "2019–2020".
    let years: String
    /// TV model years that shipped with this remote (used to preselect it in the picker).
    let modelYears: [Int]
    /// `magic` (pointer remote) or `standard`.
    let kind: String
    /// File name of the image next to the json (lossless WebP, decoded by ImageIO).
    let image: String
    /// Pixel size of the image, `[width, height]`.
    let imageSize: [Double]
    let keys: [RemoteKeySpec]

    var isMagic: Bool { kind == "magic" }
    /// Width ÷ height of the picture.
    var aspectRatio: Double {
        guard imageSize.count == 2, imageSize[1] > 0 else { return 0.25 }
        return imageSize[0] / imageSize[1]
    }
}

/// One key: where it is on the picture and what it does.
struct RemoteKeySpec: Identifiable, Hashable, Decodable, Sendable {
    enum Shape: String, Decodable, Sendable { case circle, capsule, rect }

    let id: String
    /// Action vocabulary string (see `RemoteAction.init(vocabulary:)`).
    let action: String
    /// `[x, y, width, height]`, normalised 0…1 to the image.
    let rect: [Double]
    let shape: Shape
    /// Optional VoiceOver name; derived from the action when absent.
    let label: String?

    init(id: String, action: String, rect: [Double], shape: Shape = .rect, label: String? = nil) {
        self.id = id; self.action = action; self.rect = rect; self.shape = shape; self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        action = try c.decode(String.self, forKey: .action)
        rect = try c.decode([Double].self, forKey: .rect)
        // Unknown or missing shapes fall back to a rectangle rather than dropping the whole catalog.
        shape = (try? c.decode(Shape.self, forKey: .shape)) ?? .rect
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }

    private enum CodingKeys: String, CodingKey { case id, action, rect, shape, label }

    /// Parsed action; nil when the vocabulary string isn't understood (the key is then skipped).
    var remoteAction: RemoteAction? { RemoteAction(vocabulary: action) }

    /// The rect as a `CGRect` in unit coordinates; nil when malformed.
    var unitRect: CGRect? {
        guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0 else { return nil }
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }
}

struct RemoteCatalogFile: Decodable, Sendable {
    let version: Int
    let remotes: [RemoteSpec]
}

// MARK: - Action vocabulary

extension RemoteAction {
    /// Parses the catalog's action vocabulary: `power`, `volumeUp`, `volumeDown`, `channelUp`, `channelDown`,
    /// `voice`, `inputs`, `key:<RemoteKey rawValue>`, `app:<id or title match>` (brand keys such as Netflix), `unsupported:<Human name>`.
    init?(vocabulary raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s {
        case "power": self = .power
        case "volumeUp": self = .volumeUp
        case "volumeDown": self = .volumeDown
        case "channelUp": self = .channelUp
        case "channelDown": self = .channelDown
        case "voice": self = .voice
        case "inputs": self = .inputs
        default:
            guard let colon = s.firstIndex(of: ":") else { return nil }
            let head = s[..<colon], tail = String(s[s.index(after: colon)...])
            switch head {
            case "key":
                guard let key = RemoteKey(rawValue: tail) ?? RemoteKey(rawValue: tail.uppercased()) else { return nil }
                self = .key(key)
            case "app":
                let match = tail.trimmingCharacters(in: .whitespaces)
                guard !match.isEmpty else { return nil }
                self = .launch(app: match)
            case "unsupported":
                let name = tail.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                self = .unsupported(name)
            default: return nil
            }
        }
    }

    /// The vocabulary string for this action (inverse of `init(vocabulary:)`).
    var vocabulary: String {
        switch self {
        case .power: "power"
        case .volumeUp: "volumeUp"
        case .volumeDown: "volumeDown"
        case .channelUp: "channelUp"
        case .channelDown: "channelDown"
        case .voice: "voice"
        case .inputs: "inputs"
        case .key(let k): "key:\(k.rawValue)"
        case .launch(let match): "app:\(match)"
        case .unsupported(let name): "unsupported:\(name)"
        }
    }

    /// Default VoiceOver name.
    var spokenName: String {
        switch self {
        case .power: String(localized: "Power")
        case .volumeUp: String(localized: "Volume up")
        case .volumeDown: String(localized: "Volume down")
        case .channelUp: String(localized: "Channel up")
        case .channelDown: String(localized: "Channel down")
        case .voice: String(localized: "Voice")
        case .inputs: String(localized: "Input")
        case .launch(let match): RemoteAction.appName(match)
        case .unsupported(let name): name
        case .key(let k): k.spokenName
        }
    }
}

extension RemoteKey {
    var spokenName: String {
        switch self {
        case .home: String(localized: "Home")
        case .back: String(localized: "Back")
        case .exit: String(localized: "Exit")
        case .menu: String(localized: "Menu")
        case .qMenu: String(localized: "Settings")
        case .info: String(localized: "Info")
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .enter: String(localized: "OK")
        case .volumeUp: String(localized: "Volume up")
        case .volumeDown: String(localized: "Volume down")
        case .mute: String(localized: "Mute")
        case .channelUp: String(localized: "Channel up")
        case .channelDown: String(localized: "Channel down")
        case .red: String(localized: "Red")
        case .green: String(localized: "Green")
        case .yellow: String(localized: "Yellow")
        case .blue: String(localized: "Blue")
        case .play: String(localized: "Play")
        case .pause: String(localized: "Pause")
        case .stop: String(localized: "Stop")
        case .rewind: String(localized: "Rewind")
        case .fastForward: String(localized: "Fast forward")
        case .record: String(localized: "Record")
        case .dash: String(localized: "Dash")
        case .asterisk: String(localized: "Asterisk")
        case .list: String(localized: "List")
        case .guide: String(localized: "Guide")
        case .flashback: String(localized: "Previous channel")
        case .cc: String(localized: "Subtitles")
        case .sap: String(localized: "Audio description")
        case .aspectRatio: String(localized: "Aspect ratio")
        case .screenRemote: String(localized: "Screen remote")
        case .liveZoom: String(localized: "Live zoom")
        case .teletext: String(localized: "Text")
        case .textOption: String(localized: "Text options")
        case .magnifierZoom: String(localized: "Magnifier")
        case .threeD: String(localized: "3D")
        case .program: String(localized: "Program")
        case .favorites: String(localized: "Favourites")
        case .search: String(localized: "Search")
        case .inputHub: String(localized: "Input")
        case .eManual: String(localized: "User guide")
        case .power: String(localized: "Power")
        case .myApps: String(localized: "My apps")
        case .recent: String(localized: "Recent")
        case .amazon: String(localized: "Prime Video")
        case .netflix: String(localized: "Netflix")
        default: rawValue // digits
        }
    }
}

// MARK: - Catalog

/// The remotes available to pick from. Loads the real catalog from the bundle, or the placeholder one.
struct RemoteCatalog: Sendable {
    /// UserDefaults key of the chosen remote's id.
    static let selectedIDKey = "remote.selectedID"

    let remotes: [RemoteSpec]
    /// True when the real catalog wasn't found and the placeholder art is in use.
    let isPlaceholder: Bool

    static let shared: RemoteCatalog = load(bundle: .main)

    static func load(bundle: Bundle) -> RemoteCatalog {
        if let url = resourceURL("remotes.json", bundle: bundle),
           let file = try? decode(Data(contentsOf: url)), !file.remotes.isEmpty {
            return RemoteCatalog(remotes: file.remotes, isPlaceholder: false)
        }
        if let url = resourceURL("placeholder-remotes.json", bundle: bundle),
           let file = try? decode(Data(contentsOf: url)) {
            return RemoteCatalog(remotes: file.remotes, isPlaceholder: true)
        }
        return RemoteCatalog(remotes: [], isPlaceholder: true)
    }

    static func decode(_ data: Data) throws -> RemoteCatalogFile {
        let file = try JSONDecoder().decode(RemoteCatalogFile.self, from: data)
        // Drop remotes whose image size is unusable or whose keys aren't mapped yet (catalog skeleton entries);
        // keys with bad rects/actions are skipped at draw time.
        return RemoteCatalogFile(version: file.version,
                                 remotes: file.remotes.filter {
                                     $0.imageSize.count == 2 && $0.imageSize.allSatisfy { $0 > 0 } && !$0.keys.isEmpty
                                 })
    }

    /// Resources in the synchronized `OpenRemote` group are copied flat into the bundle; also try a `Remotes/` folder.
    static func resourceURL(_ fileName: String, bundle: Bundle) -> URL? {
        let ns = fileName as NSString
        let name = ns.deletingPathExtension, ext = ns.pathExtension
        return bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Remotes")
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/Remotes")
    }

    func remote(id: String?) -> RemoteSpec? {
        guard let id else { return nil }
        return remotes.first { $0.id == id }
    }

    /// The remote the user picked, or the newest Magic Remote.
    var selected: RemoteSpec? {
        remote(id: UserDefaults.standard.string(forKey: Self.selectedIDKey))
            ?? remote(id: defaultID(forModelYear: nil))
    }

    /// The remote that shipped with TVs of `year` (Magic Remote preferred when a year has both kinds);
    /// otherwise the newest Magic Remote.
    func defaultID(forModelYear year: Int?) -> String? {
        if let year {
            let matches = remotes.filter { $0.modelYears.contains(year) }
            if let pick = matches.first(where: \.isMagic) ?? matches.first { return pick.id }
        }
        let newestMagic = remotes.filter(\.isMagic).max { ($0.modelYears.max() ?? 0) < ($1.modelYears.max() ?? 0) }
        return newestMagic?.id ?? remotes.first?.id
    }

    /// Convenience over the shared catalog.
    static func defaultID(forModelYear year: Int?) -> String? { shared.defaultID(forModelYear: year) }

    /// Best guess of an LG TV's model year from its model name (e.g. "OLED65C9PUA" → 2019, "55UN7300" → 2020); nil when
    /// the name doesn't follow LG's scheme. The TV's model year from its model name (e.g. 55SM8000 → 2019). Delegates to the shared, tested mapping.
    static func modelYear(fromModelName name: String?) -> Int? {
        TVModelYear.year(modelName: name)
    }
}

// MARK: - Images

/// Loads (and caches) remote pictures, downsampled to the size they're drawn at.
enum RemoteImageStore {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    /// - Parameter maxPixelHeight: decode at most this many pixels tall (nil = full size).
    static func image(for spec: RemoteSpec, maxPixelHeight: Int? = nil, bundle: Bundle = .main) -> UIImage? {
        let key = "\(spec.image)#\(maxPixelHeight ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = RemoteCatalog.resourceURL(spec.image, bundle: bundle) else { return nil }
        let image: UIImage?
        if let maxPixelHeight, maxPixelHeight < Int(spec.imageSize.last ?? 0) {
            let maxSide = max(Double(maxPixelHeight), Double(maxPixelHeight) * spec.aspectRatio)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSide.rounded(.up)),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                .map { UIImage(cgImage: $0) }
        } else {
            image = UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
