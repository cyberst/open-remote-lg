// lgctl — exercise LGTVClient against a real TV from the shell.
//
//   swift run lgctl --host 192.168.178.250 --key-file client-key.txt [secure|plain] [-v] <command> [args]
//
// Commands can be chained with "--": `lgctl ... volume -- mute on -- toast hi`.
import Foundation
@_spi(Debug) import LGKit

let usage = """
usage: lgctl --host HOST [--key-file FILE] [--id ID] [--max-volume N] [secure|plain] [-v] <command> [-- <command> ...]
commands:
  connect                     connect only (prints timing)
  info                        model, webOS version, MACs, device name
  volume [N]                  read volume, or set it (refuses > --max-volume, default 3)
  vol+ | vol-                 volume up / down (refuses going above --max-volume)
  mute on|off
  button NAME [NAME...]       pointer-socket buttons, e.g. HOME UP DOWN BACK ENTER
  apps | icons | launch ID | foreground
  inputs | input ID
  channels | channel
  toast MESSAGE
  text STRING [replace]       IME insertText;  delete N;  enter
  move DX DY [drag] | click | scroll DX DY
  watch [SECONDS]             print state / volume / foreground app / keyboard events
  drop                        simulate a network drop and wait for auto-reconnect
  sleep-timer MIN|off         app-side sleep timer (never fires within lgctl's lifetime unless you wait)
  request URI [JSON]          raw SSAP request (power-off URIs are refused)
  pause SECONDS
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    exit(1)
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
var host: String?
var keyFile: String?
var deviceID: String?
var secure: Bool?
var verbose = false
var maxVolume = 3
var commandWords: [String] = []

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--host": host = args.isEmpty ? nil : args.removeFirst()
    case "--key-file": keyFile = args.isEmpty ? nil : args.removeFirst()
    case "--id": deviceID = args.isEmpty ? nil : args.removeFirst()
    case "--max-volume": maxVolume = Int(args.isEmpty ? "" : args.removeFirst()) ?? 3
    case "secure", "--secure": secure = true
    case "plain", "--plain": secure = false
    case "-v", "--verbose": verbose = true
    case "-h", "--help": print(usage); exit(0)
    default: commandWords.append(a); commandWords.append(contentsOf: args); args.removeAll()
    }
}
guard let host else { fail(usage) }
if commandWords.isEmpty { commandWords = ["info"] }

var commands: [[String]] = [[]]
for w in commandWords { if w == "--" { commands.append([]) } else { commands[commands.count - 1].append(w) } }
commands.removeAll { $0.isEmpty }

let id = deviceID ?? "host:\(host)"
let keys = InMemoryKeyStore()
var initialKey: String?
if let keyFile {
    if let k = try? String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
        keys.setClientKey(k, for: id); initialKey = k
    } else {
        print("note: key file empty or unreadable; the TV will ask for pairing")
    }
}

let device = TVDevice(id: id, name: host, host: host, useSecureSocket: secure)
enum Clock {
    static let start = Date()
    @Sendable static func elapsed() -> String { String(format: "%6.3fs", Date().timeIntervalSince(start)) }
}
_ = Clock.start
func elapsed() -> String { Clock.elapsed() }
let logger: (@Sendable (String) -> Void)? = verbose ? { @Sendable (line: String) -> Void in print("  [\(Clock.elapsed())] \(line)") } : nil
let tv = LGTVClient(device: device, keyStore: keys, log: logger)

func show(_ j: JSON) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: j.data()), options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return "\(j)" }
    return s.count > 4000 ? String(s.prefix(4000)) + "\n…" : s
}

// MARK: Run

let stateTask = Task.detached {
    for await s in tv.observeState() { print("[\(elapsed())] state: \(s)") }
}

func run() async {
    do {
        let t0 = Date()
        try await tv.connect()
        print(String(format: "connected in %.0f ms", Date().timeIntervalSince(t0) * 1000))
        for cmd in commands { try await execute(cmd) }
    } catch {
        print("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    }
    let k = keys.clientKey(for: id)
    if let k, k != initialKey { print("NEW client key: \(k)") }
    let d = await tv.refreshedDevice()
    print("refreshedDevice: secure=\(d.useSecureSocket.map(String.init) ?? "nil") model=\(d.modelName ?? "-") webOS=\(d.webOSVersion ?? "-") macs=\(d.macAddresses)")
    await tv.disconnect()
}

func execute(_ cmd: [String]) async throws {
    let name = cmd[0], rest = Array(cmd.dropFirst())
    print("» \(cmd.joined(separator: " "))")
    switch name {
    case "connect": break
    case "info":
        let i = try await tv.info()
        print("model: \(i.modelName ?? "-")\nwebOS: \(i.webOSVersion ?? "-")\nfirmware: \(i.firmwareVersion ?? "-")\nname: \(i.deviceName ?? "-")\nMACs: \(i.macAddresses)\nextra: \(i.extra)")
    case "volume":
        if let n = rest.first.flatMap(Int.init) {
            guard n <= maxVolume else { fail("refusing: volume \(n) > max \(maxVolume)") }
            try await tv.setVolume(n)
        }
        print(try await tv.volume())
    case "vol+":
        guard try await tv.volume().volume < maxVolume else { fail("refusing: volume already at max \(maxVolume)") }
        try await tv.volumeUp(); print(try await tv.volume())
    case "vol-":
        try await tv.volumeDown(); print(try await tv.volume())
    case "mute":
        try await tv.setMute(rest.first != "off"); print(try await tv.volume())
    case "button":
        for b in rest {
            guard let key = RemoteKey(rawValue: b.uppercased()) else { fail("unknown button \(b)") }
            guard key != .power else { fail("refusing: POWER") }
            if key == .volumeUp, try await tv.volume().volume >= maxVolume { fail("refusing: volume at max") }
            let t = Date()
            try await tv.press(key)
            print(String(format: "  %@ sent (%.0f ms)", b, Date().timeIntervalSince(t) * 1000))
            if rest.count > 1 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
    case "apps":
        let apps = try await tv.apps()
        for a in apps { print("  \(a.id)  \"\(a.title)\"  \(a.iconURL?.absoluteString ?? "-")") }
        print("\(apps.count) apps")
    case "icons":
        for a in try await tv.apps().prefix(3) {
            guard let u = a.iconURL else { continue }
            let d = try await tv.resourceData(from: u)
            print("  \(a.id): \(d.count) bytes PNG=\(d.starts(with: [0x89, 0x50, 0x4E, 0x47]))  \(u.absoluteString)")
        }
    case "launch":
        guard let appID = rest.first else { fail("launch ID") }
        try await tv.launchApp(id: appID, params: nil)
    case "foreground": print(try await tv.foregroundAppID() ?? "-")
    case "inputs":
        for i in try await tv.inputs() { print("  \(i.id)  \"\(i.label)\"  app=\(i.appId ?? "-") connected=\(i.connected) icon=\(i.iconURL?.absoluteString ?? "-")") }
    case "input":
        guard let inputID = rest.first else { fail("input ID") }
        try await tv.switchInput(id: inputID)
    case "channels":
        let ch = try await tv.channels()
        for c in ch.prefix(20) { print("  \(c.number) \(c.name) [\(c.id)]") }
        print("\(ch.count) channels")
    case "channel": print(String(describing: try await tv.currentChannel()))
    case "toast": try await tv.showToast(rest.joined(separator: " "))
    case "text": try await tv.insertText(rest.first ?? "", replace: rest.dropFirst().first == "replace")
    case "delete": try await tv.deleteCharacters(Int(rest.first ?? "1") ?? 1)
    case "enter": try await tv.sendEnter()
    case "move":
        guard rest.count >= 2, let dx = Double(rest[0]), let dy = Double(rest[1]) else { fail("move DX DY") }
        try await tv.pointerMove(dx: dx, dy: dy, drag: rest.dropFirst(2).first == "drag")
    case "click": try await tv.pointerClick()
    case "scroll":
        guard rest.count >= 2, let dx = Double(rest[0]), let dy = Double(rest[1]) else { fail("scroll DX DY") }
        try await tv.pointerScroll(dx: dx, dy: dy)
    case "watch":
        let seconds = Double(rest.first ?? "10") ?? 10
        let tasks = [
            Task { for await v in tv.observeVolume() { print("[\(elapsed())] volume: \(v)") } },
            Task { for await a in tv.observeForegroundApp() { print("[\(elapsed())] foreground: \(a)") } },
            Task { for await k in tv.observeKeyboard() { print("[\(elapsed())] keyboard: \(k)") } },
        ]
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        tasks.forEach { $0.cancel() }
    case "drop":
        let t = Date()
        await tv.simulateNetworkDrop()
        _ = try await tv.volume() // waits for the automatic reconnect
        print(String(format: "  reconnected and answered in %.0f ms", Date().timeIntervalSince(t) * 1000))
    case "sleep-timer":
        try await tv.setSleepTimer(minutes: rest.first == "off" ? nil : Int(rest.first ?? ""))
        print("remaining: \(await tv.sleepTimerRemaining().map { "\($0) min" } ?? "off") (support: \(tv.sleepTimerSupport))")
    case "request":
        guard let uri = rest.first else { fail("request URI [JSON]") }
        let lower = uri.lowercased()
        guard !lower.contains("turnoff") || lower.contains("screen"), !lower.contains("poweroff") else { fail("refusing: power off") }
        var payload: JSON?
        if rest.count > 1 { payload = try JSON.parse(Data(rest.dropFirst().joined(separator: " ").utf8)) }
        if lower.contains("setvolume"), let v = payload?["volume"]?.intValue, v > maxVolume { fail("refusing: volume > \(maxVolume)") }
        print(show(try await tv.request(uri, payload: payload)))
    case "pause":
        try await Task.sleep(nanoseconds: UInt64((Double(rest.first ?? "1") ?? 1) * 1_000_000_000))
    default:
        fail("unknown command \(name)\n\(usage)")
    }
}

let done = DispatchSemaphore(value: 0)
Task.detached { await run(); stateTask.cancel(); done.signal() }
done.wait()
