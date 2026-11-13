import XCTest
@testable import LGKit

final class WebOSClientTests: XCTestCase {

    // MARK: Registration & pairing

    func testRegistrationWithStoredKeySkipsPairing() async throws {
        let tv = FakeTV(); tv.validKeys = ["KEY1"]
        let keys = InMemoryKeyStore(); keys.setClientKey("KEY1", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        await rec.waitFor { $0 == .connected }
        XCTAssertFalse(rec.all.contains { if case .pairing = $0 { return true } else { return false } })
        XCTAssertEqual(tv.registerMessages().first?["payload"]?["client-key"]?.stringValue, "KEY1")
        XCTAssertEqual(keys.clientKey(for: "tv1"), "KEY1")
        // Manifest is sent intact.
        XCTAssertEqual(tv.registerMessages().first?["payload"]?["manifest"]?["permissions"]?.arrayValue?.count,
                       RegistrationManifest.permissions.count)
    }

    func testPromptPairingSavesNewKey() async throws {
        let tv = FakeTV(); tv.pairing = .accept(after: 0.1)
        let keys = InMemoryKeyStore()
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        XCTAssertTrue(rec.all.contains(.pairing(.acceptOnTV)), "\(rec.all)")
        XCTAssertEqual(keys.clientKey(for: "tv1"), "NEWKEY")
        XCTAssertEqual(tv.registerMessages().first?["payload"]?["pairingType"]?.stringValue, "PROMPT")
        XCTAssertNil(tv.registerMessages().first?["payload"]?["client-key"])
    }

    func testPINPairing() async throws {
        let tv = FakeTV()
        let keys = InMemoryKeyStore()
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        let connecting = Task { try await client.connect(preferPIN: true) }
        await rec.waitFor { $0 == .pairing(.enterPIN) }
        do {
            try await client.submitPairingPIN("0000")
            XCTFail("wrong PIN should throw")
        } catch LGError.tvError(let m) {
            XCTAssertTrue(m.contains("Wrong PIN"), m)
        }
        XCTAssertEqual(rec.all.last, .pairing(.enterPIN), "stays in PIN entry after a wrong PIN")
        try await client.submitPairingPIN(" 1234 ")
        try await connecting.value
        XCTAssertEqual(keys.clientKey(for: "tv1"), "NEWKEY")
        XCTAssertEqual(tv.registerMessages().first?["payload"]?["pairingType"]?.stringValue, "PIN")
        await rec.waitFor { $0 == .connected }
    }

    func testRejectedKeyIsClearedAndPromptPairingFollows() async throws {
        let tv = FakeTV() // "OLD" is not valid
        let keys = InMemoryKeyStore(); keys.setClientKey("OLD", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        XCTAssertTrue(rec.all.contains(.pairing(.acceptOnTV)))
        XCTAssertEqual(keys.clientKey(for: "tv1"), "NEWKEY")
    }

    func testRejectedKeyErrorStyleRetriesWithoutKey() async throws {
        let tv = FakeTV(); tv.keyRejection = .error
        let keys = InMemoryKeyStore(); keys.setClientKey("OLD", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        let regs = tv.registerMessages()
        XCTAssertEqual(regs.count, 2)
        XCTAssertEqual(regs[0]["payload"]?["client-key"]?.stringValue, "OLD")
        XCTAssertNil(regs[1]["payload"]?["client-key"])
        XCTAssertEqual(keys.clientKey(for: "tv1"), "NEWKEY")
    }

    func testDenyOnTVThrowsPairingRejected() async throws {
        let tv = FakeTV(); tv.pairing = .deny(after: 0.05)
        let client = makeClient(tv)
        let rec = StateRecorder(client)
        do {
            try await client.connect()
            XCTFail("expected pairingRejected")
        } catch LGError.pairingRejected {}
        await rec.waitFor { if case .failed = $0 { return true } else { return false } }
        // Denial must not trigger auto-reconnect loops.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(rec.all.contains { if case .reconnecting = $0 { return true } else { return false } })
    }

    func testPairingTimeout() async throws {
        let tv = FakeTV(); tv.pairing = .never
        var timing = SSAPTiming.fast; timing.pairingTimeout = 0.2
        let client = makeClient(tv, timing: timing)
        do { try await client.connect(); XCTFail() } catch LGError.timeout {}
    }

    // MARK: Transport selection

    func testSecureIsPreferredAndRemembered() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        let d = await client.refreshedDevice()
        XCTAssertEqual(d.useSecureSocket, true)
    }

    func testFallsBackToPlainWhen3001Refused() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]; tv.refusedPorts = [3001]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        let d = await client.refreshedDevice()
        XCTAssertEqual(d.useSecureSocket, false)
    }

    func testKnownPreferenceFallsBackToOtherPort() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]; tv.refusedPorts = [3000]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys, secure: false) // remembered plain, but firmware update closed 3000
        try await client.connect()
        let d = await client.refreshedDevice()
        XCTAssertEqual(d.useSecureSocket, true)
    }

    func testUnreachableTVFailsFast() async throws {
        let tv = FakeTV(); tv.reachable = false
        let client = makeClient(tv)
        let rec = StateRecorder(client)
        let start = Date()
        do { try await client.connect(); XCTFail() } catch LGError.network {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await rec.waitFor { if case .failed = $0 { return true } else { return false } }
    }

    func testConcurrentConnectsShareOneSession() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]; tv.refusedPorts = [3000]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys, secure: true)
        async let a: Void = client.connect()
        async let b: Void = client.connect()
        _ = try await (a, b)
        try await client.connect() // already connected: returns immediately
        XCTAssertEqual(tv.registerMessages().count, 1)
    }

    func testConnectWhileUpRevivesZombieSocket() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        tv.answersPings = false // e.g. socket silently died while the app was suspended
        try await client.connect()
        XCTAssertEqual(tv.registerMessages().count, 2, "a dead-looking socket is replaced right away")
        tv.answersPings = true
        try await client.connect()
        XCTAssertEqual(tv.registerMessages().count, 2, "a healthy socket is kept")
    }

    // MARK: Requests

    func testRequestTimeout() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://system/getSystemInfo") { _ in .noReply }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        do { _ = try await client.request("ssap://system/getSystemInfo", payload: nil); XCTFail() } catch LGError.timeout {}
    }

    func testErrorMapping() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://a/perm") { _ in .error("401 insufficient permissions") }
        tv.set("ssap://a/fail") { _ in .payload(["returnValue": false, "errorText": "tuner channel map does not exist"]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        do { _ = try await client.request("a/perm", payload: nil); XCTFail() } catch LGError.tvError(let m) { XCTAssertTrue(m.hasPrefix("401")) }
        do { _ = try await client.request("ssap://a/missing", payload: nil); XCTFail() } catch LGError.unsupported {}
        do { _ = try await client.request("ssap://a/fail", payload: nil); XCTFail() } catch LGError.tvError(let m) { XCTAssertTrue(m.contains("tuner"), m) }
    }

    func testNotConnectedFailsFast() async throws {
        let client = makeClient(FakeTV())
        do { _ = try await client.volume(); XCTFail() } catch LGError.notConnected {}
    }

    func testCommandPayloads() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        for uri in ["ssap://audio/setVolume", "ssap://audio/setMute", "ssap://system.launcher/launch", "ssap://tv/switchInput",
                    "ssap://com.webos.service.ime/insertText", "ssap://com.webos.service.ime/deleteCharacters",
                    "ssap://system.notifications/createToast", "ssap://system/turnOff", "ssap://system.launcher/open",
                    "ssap://media.controls/fastForward"] {
            tv.set(uri) { _ in .payload(["returnValue": true]) }
        }
        tv.set("ssap://media.viewer/open") { _ in .payload(["returnValue": true, "sessionId": "S1"]) }
        tv.set("ssap://media.viewer/close") { _ in .payload(["returnValue": true]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        try await client.setVolume(150)
        XCTAssertEqual(tv.messages(uri: "ssap://audio/setVolume").last?["payload"]?["volume"]?.intValue, 100)
        try await client.setMute(true)
        XCTAssertEqual(tv.messages(uri: "ssap://audio/setMute").last?["payload"]?["mute"]?.boolValue, true)
        try await client.launchApp(id: "netflix", params: ["contentId": "x"])
        XCTAssertEqual(tv.messages(uri: "ssap://system.launcher/launch").last?["payload"], ["id": "netflix", "params": ["contentId": "x"]])
        try await client.switchInput(id: "HDMI_2")
        XCTAssertEqual(tv.messages(uri: "ssap://tv/switchInput").last?["payload"]?["inputId"]?.stringValue, "HDMI_2")
        try await client.insertText("hi", replace: true)
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.ime/insertText").last?["payload"], ["text": "hi", "replace": 1])
        try await client.deleteCharacters(3)
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.ime/deleteCharacters").last?["payload"]?["count"]?.intValue, 3)
        try await client.showToast("Hello")
        XCTAssertEqual(tv.messages(uri: "ssap://system.notifications/createToast").last?["payload"]?["message"]?.stringValue, "Hello")
        try await client.powerOff() // fake TV only — never on the real test TV
        XCTAssertEqual(tv.messages(uri: "ssap://system/turnOff").count, 1)
        try await client.openURLInBrowser(URL(string: "https://example.com")!)
        XCTAssertEqual(tv.messages(uri: "ssap://system.launcher/open").last?["payload"]?["target"]?.stringValue, "https://example.com")
        try await client.media(.fastForward)
        XCTAssertEqual(tv.messages(uri: "ssap://media.controls/fastForward").count, 1)
        try await client.openMedia(url: URL(string: "http://10.0.0.2:8080/a.jpg")!, mimeType: "image/jpeg", title: nil, iconURL: nil)
        XCTAssertEqual(tv.messages(uri: "ssap://media.viewer/open").last?["payload"]?["title"]?.stringValue, "a.jpg")
        try await client.closeMedia()
        XCTAssertEqual(tv.messages(uri: "ssap://media.viewer/close").last?["payload"]?["sessionId"]?.stringValue, "S1")
    }

    func testScreenOffFallsBackToOlderURI() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://com.webos.service.tv.power/turnOffScreen") { _ in .payload(["returnValue": true]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        try await client.screenOff()
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.tvpower/power/turnOffScreen").count, 1)
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.tv.power/turnOffScreen").count, 1)
        // No screen-on call on this firmware: a harmless remote key wakes the picture instead.
        try await client.screenOn()
        XCTAssertEqual(tv.frames, ["type:button\nname:INFO\n\n"])
    }

    func testObserveScreenOffFollowsTVAndOwnCommands() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let power = "ssap://com.webos.service.tvpower/power/getPowerState"
        tv.set(power) { _ in .payload(["returnValue": true, "state": "Active"]) }
        tv.set("ssap://com.webos.service.tvpower/power/turnOffScreen") { _ in .payload(["returnValue": true]) }
        tv.set("ssap://com.webos.service.tvpower/power/turnOnScreen") { _ in .payload(["returnValue": true]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()

        let screen = Collector(client.observeScreenOff())
        do { let ok = await eventually { screen.values == [false] }; XCTAssertTrue(ok) }
        try await client.screenOff()
        do { let ok = await eventually { screen.values == [false, true] }; XCTAssertTrue(ok) }
        // A key on the TV's own remote brings the picture back; the TV reports it.
        tv.push(power, ["state": "Active"])
        do { let ok = await eventually { screen.values == [false, true, false] }; XCTAssertTrue(ok) }
        tv.push(power, ["state": "Screen Off"])
        do { let ok = await eventually { screen.values.last == true }; XCTAssertTrue(ok) }
        try await client.screenOn()
        do { let ok = await eventually { screen.values.last == false }; XCTAssertTrue(ok) }
    }

    // MARK: Subscriptions & reconnection

    func testSubscriptionFanOutAndResubscribeAfterReconnect() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()

        let a = Collector(client.observeVolume())
        let b = Collector(client.observeVolume())
        do { let ok = await eventually { a.values.count == 1 && b.values.count == 1 }; XCTAssertTrue(ok) }
        XCTAssertEqual(a.values.first?.volume, 3)

        tv.push("ssap://audio/getVolume", ["volumeStatus": ["volume": 2, "muteStatus": true, "soundOutput": "tv_speaker"]])
        do { let ok = await eventually { a.values.count == 2 && b.values.count == 2 }; XCTAssertTrue(ok) }
        XCTAssertEqual(b.values.last, VolumeState(volume: 2, muted: true, scenario: "tv_speaker"))
        // A late subscriber gets the current value immediately.
        let c = Collector(client.observeVolume())
        do { let ok = await eventually { c.values == [VolumeState(volume: 2, muted: true, scenario: "tv_speaker")] }; XCTAssertTrue(ok) }

        tv.dropConnections()
        await rec.waitFor { if case .reconnecting = $0 { return true } else { return false } }
        await rec.waitFor { $0 == .connected }
        do { let ok = await eventually { tv.liveSubscriptionCount(uri: "ssap://audio/getVolume") == 1 }; XCTAssertTrue(ok) }
        XCTAssertEqual(tv.messages(uri: "ssap://audio/getVolume").filter { $0["type"] == "subscribe" }.count, 2)

        tv.push("ssap://audio/getVolume", ["volume": 1, "muted": false])
        do { let ok = await eventually { a.values.last?.volume == 1 && b.values.last?.volume == 1 && c.values.last?.volume == 1 }; XCTAssertTrue(ok) }
    }

    func testReconnectBackoffStateSequenceThenFailed() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        tv.reachable = false
        tv.dropConnections()
        await rec.waitFor { if case .failed = $0 { return true } else { return false } }
        let tail = rec.all.drop { $0 != .connected }.dropFirst()
        XCTAssertEqual(Array(tail.prefix(4)), [.reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3), .reconnecting(attempt: 4)])
        if case .failed = tail.last {} else { XCTFail("\(rec.all)") }

        // TV comes back: the next command kicks a reconnect and goes through.
        tv.reachable = true
        let v = try await client.volume()
        XCTAssertEqual(v.volume, 3)
        await rec.waitFor { $0 == .connected }
    }

    func testReconnectSucceedsAfterTransientOutage() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        var timing = SSAPTiming.fast; timing.backoff = [0.05]; timing.maxReconnectAttempts = 20
        let client = makeClient(tv, keys: keys, timing: timing)
        let rec = StateRecorder(client)
        try await client.connect()
        tv.reachable = false
        tv.dropConnections()
        await rec.waitFor { $0 == .reconnecting(attempt: 2) }
        tv.reachable = true
        await rec.waitFor { $0 == .connected }
        // Requests issued while reconnecting wait for the connection instead of failing.
        tv.reachable = false
        tv.dropConnections()
        await rec.waitFor { if case .reconnecting = $0 { return true } else { return false } }
        let pending = Task { try await client.volume() }
        try await Task.sleep(nanoseconds: 60_000_000)
        tv.reachable = true
        let v = try await pending.value
        XCTAssertEqual(v.volume, 3)
    }

    func testDeadSocketDetectedByLivenessCheck() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://slow") { _ in .noReply }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        var timing = SSAPTiming.fast; timing.pingInterval = 0.05
        let client = makeClient(tv, keys: keys, timing: timing)
        let rec = StateRecorder(client)
        try await client.connect()
        // TV stops answering pings AND requests: the socket is a zombie.
        tv.answersPings = false
        tv.set("ssap://audio/getVolume") { _ in .noReply }
        await rec.waitFor { if case .reconnecting = $0 { return true } else { return false } }
    }

    func testFirmwareWithoutPongsStaysConnected() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]; tv.answersPings = false
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        var timing = SSAPTiming.fast; timing.pingInterval = 0.03
        let client = makeClient(tv, keys: keys, timing: timing)
        let rec = StateRecorder(client)
        try await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rec.all.last, .connected)
        XCTAssertFalse(rec.all.contains { if case .reconnecting = $0 { return true } else { return false } })
    }

    func testDisconnectStopsEverything() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        await client.disconnect()
        await rec.waitFor { $0 == .disconnected }
        tv.dropConnections()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rec.all.last, .disconnected)
        do { try await client.press(.home); XCTFail() } catch LGError.notConnected {}
    }

    // MARK: Pointer socket

    func testPointerFramesAndMoveCoalescing() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        try await client.press(.home)
        XCTAssertEqual(tv.frames, ["type:button\nname:HOME\n\n"])

        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<100 { g.addTask { try? await client.pointerMove(dx: 1.5, dy: -1, drag: false) } }
        }
        try await client.pointerClick() // flushes remaining movement first
        let moves = tv.frames.filter { $0.hasPrefix("type:move") }
        XCTAssertLessThan(moves.count, 50, "moves must be coalesced")
        func sum(_ key: String) -> Int {
            moves.compactMap { f in f.split(separator: "\n").first { $0.hasPrefix(key + ":") }.flatMap { Int($0.dropFirst(key.count + 1)) } }.reduce(0, +)
        }
        XCTAssertEqual(sum("dx"), 150)
        XCTAssertEqual(sum("dy"), -100)
        XCTAssertEqual(tv.frames.last, "type:click\n\n")
        try await client.pointerScroll(dx: 0, dy: -3)
        XCTAssertEqual(tv.frames.last, "type:scroll\ndx:0\ndy:-3\n\n")
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket").count, 1, "pointer socket is reused")
    }

    func testPointerSocketReopensAfterReconnect() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        let rec = StateRecorder(client)
        try await client.connect()
        try await client.press(.up)
        tv.dropConnections()
        await rec.waitFor { if case .reconnecting = $0 { return true } else { return false } }
        await rec.waitFor { $0 == .connected }
        try await client.press(.down)
        XCTAssertEqual(tv.frames, ["type:button\nname:UP\n\n", "type:button\nname:DOWN\n\n"])
        XCTAssertEqual(tv.messages(uri: "ssap://com.webos.service.networkinput/getPointerInputSocket").count, 2)
    }

    func testVolumeKeysUseSSAP() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://audio/volumeUp") { _ in .payload(["returnValue": true]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        try await client.press(.volumeUp)
        XCTAssertEqual(tv.messages(uri: "ssap://audio/volumeUp").count, 1)
        XCTAssertTrue(tv.frames.isEmpty)
    }

    func testPointerAlternateURL() {
        XCTAssertEqual(PointerChannel.alternateURL(URL(string: "ws://h:3000/resources/x/netinput.pointer.sock")!)?.absoluteString,
                       "wss://h:3001/resources/x/netinput.pointer.sock")
        XCTAssertNil(PointerChannel.alternateURL(URL(string: "ws://h:8080/x")!))
    }

    // MARK: Info

    func testInfoCombinesSources() async throws {
        let tv = FakeTV(); tv.validKeys = ["K"]
        tv.set("ssap://system/getSystemInfo") { _ in .payload(["modelName": "OLED55C9PLA", "receiverType": "dvb", "returnValue": true]) }
        tv.set("ssap://com.webos.service.update/getCurrentSWInformation") { _ in .error("401 insufficient permissions") }
        tv.set("ssap://com.webos.service.connectionmanager/getinfo") { _ in
            .payload(["wiredInfo": ["macAddress": "aa:bb:cc:dd:ee:ff"], "wifiInfo": ["macAddress": "11:22:33:44:55:66"], "returnValue": true])
        }
        tv.set("ssap://settings/getSystemSettings") { _ in .payload(["settings": ["deviceName": "Living Room"], "returnValue": true]) }
        let keys = InMemoryKeyStore(); keys.setClientKey("K", for: "tv1")
        let client = makeClient(tv, keys: keys)
        try await client.connect()
        let info = try await client.info()
        XCTAssertEqual(info.modelName, "OLED55C9PLA")
        XCTAssertEqual(info.webOSVersion, "4.5")
        XCTAssertEqual(info.macAddresses, ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"])
        XCTAssertEqual(info.deviceName, "Living Room")
        let d = await client.refreshedDevice()
        XCTAssertEqual(d.name, "Living Room", "empty name is filled from the TV")
        XCTAssertEqual(d.macAddresses.count, 2)
    }
}

/// Collects values from an AsyncStream in the background.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<T>) {
        task = Task { [weak self] in for await v in stream { self?.add(v) } }
    }
    deinit { task?.cancel() }
    private func add(_ v: T) { lock.withLock { items.append(v) } }
    var values: [T] { lock.withLock { items } }
}
