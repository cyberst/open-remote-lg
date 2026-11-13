import XCTest
@testable import LGKit

/// Payload fixtures captured from / modelled on different webOS generations.
final class WebOSParserTests: XCTestCase {
    private func json(_ s: String) -> JSON { (try? JSON.parse(Data(s.utf8))) ?? .null }

    func testVolumeWebOS3and4() {
        // webOS 4.5 (55SM8000PLA), captured.
        let p = json(#"{"returnValue":true,"scenario":"mastervolume_tv_speaker","volume":3,"muted":true}"#)
        XCTAssertEqual(SSAPParsers.volume(p), VolumeState(volume: 3, muted: true, scenario: "mastervolume_tv_speaker"))
        // webOS 4.5 subscription event, captured.
        let s = json(#"{"returnValue":true,"volumeMax":100,"scenario":"mastervolume_tv_speaker","muted":false,"subscribed":true,"volume":7,"action":"requested","supportvolume":true}"#)
        XCTAssertEqual(SSAPParsers.volume(s)?.volume, 7)
    }

    func testVolumeWebOS5Plus() {
        let p = json(#"{"returnValue":true,"callerId":"secondscreen.client","volumeStatus":{"activeStatus":true,"adjustVolume":true,"maxVolume":100,"muteStatus":true,"volume":12,"mode":"normal","soundOutput":"tv_speaker"}}"#)
        XCTAssertEqual(SSAPParsers.volume(p), VolumeState(volume: 12, muted: true, scenario: "tv_speaker"))
        // Older webOS 1/2 used "mute".
        XCTAssertEqual(SSAPParsers.volume(json(#"{"volume":"5","mute":true}"#)), VolumeState(volume: 5, muted: true))
        XCTAssertNil(SSAPParsers.volume(json(#"{"subscribed":true}"#)))
    }

    func testLaunchPointsAbsolutizeIcons() {
        let p = json(#"""
        {"launchPoints":[
          {"id":"netflix","title":"Netflix","icon":"http://192.168.1.5:3000/resources/aa/SMALL.png","mediumLargeIcon":"/media/cryptofs/x.png"},
          {"id":"com.webos.app.hdmi1","title":"HDMI 1","icon":"/resources/bb/hdmi.png"},
          {"id":"weird","title":"","icon":"/media/cryptofs/apps/icon.png"},
          {"id":"netflix","title":"Netflix (2nd launch point)"},
          {"title":"no id"}
        ]}
        """#)
        let apps = SSAPParsers.apps(p, host: "192.168.1.5")
        XCTAssertEqual(apps.map(\.id), ["netflix", "com.webos.app.hdmi1", "weird"])
        XCTAssertEqual(apps[0].iconURL?.absoluteString, "http://192.168.1.5:3000/resources/aa/SMALL.png")
        XCTAssertEqual(apps[1].iconURL?.absoluteString, "http://192.168.1.5:3000/resources/bb/hdmi.png")
        XCTAssertNil(apps[2].iconURL, "filesystem paths on the TV are not fetchable")
        XCTAssertEqual(apps[2].title, "weird")
    }

    func testListAppsDropsHidden() {
        let p = json(#"{"apps":[{"id":"a","title":"A","visible":true,"icon":"https://tv:3001/resources/1/i.png"},{"id":"b","title":"B","visible":false}]}"#)
        let apps = SSAPParsers.apps(p, host: "tv")
        XCTAssertEqual(apps.map(\.id), ["a"])
        XCTAssertEqual(apps[0].iconURL?.absoluteString, "https://tv:3001/resources/1/i.png")
    }

    func testInputs() {
        // webOS 4.5, captured (trimmed).
        let p = json(#"""
        {"returnValue":true,"devices":[
          {"id":"HDMI_1","label":"HDMI 1","port":1,"connected":false,"appId":"com.webos.app.hdmi1","icon":"http://192.168.178.250:3000/resources/2b/HDMI_1.png","modified":false,"hdmiPlugIn":false},
          {"id":"HDMI_4","label":"PS5","port":4,"connected":true,"appId":"com.webos.app.hdmi4","icon":"gameconsole.png"},
          {"id":"AV_1","label":"","connected":0}
        ]}
        """#)
        let inputs = SSAPParsers.inputs(p, host: "192.168.178.250")
        XCTAssertEqual(inputs.map(\.id), ["HDMI_1", "HDMI_4", "AV_1"])
        XCTAssertEqual(inputs[1], TVInput(id: "HDMI_4", label: "PS5", appId: "com.webos.app.hdmi4", connected: true, iconURL: nil))
        XCTAssertEqual(inputs[0].iconURL?.absoluteString, "http://192.168.178.250:3000/resources/2b/HDMI_1.png")
        XCTAssertEqual(inputs[2].label, "AV 1")
        XCTAssertFalse(inputs[2].connected)
    }

    func testForegroundApp() {
        XCTAssertEqual(SSAPParsers.foregroundApp(json(#"{"appId":"tld.my.customlauncher","returnValue":true,"windowId":"","processId":""}"#)), "tld.my.customlauncher")
        XCTAssertEqual(SSAPParsers.foregroundApp(json(#"{"subscribed":true,"appId":"","returnValue":true}"#)), "")
        XCTAssertNil(SSAPParsers.foregroundApp(json(#"{"subscribed":true}"#)))
    }

    func testScreenOff() {
        XCTAssertEqual(SSAPParsers.screenOff(json(#"{"returnValue":true,"state":"Screen Off","subscribed":true}"#)), true)
        XCTAssertEqual(SSAPParsers.screenOff(json(#"{"returnValue":true,"state":"Active","subscribed":true}"#)), false)
        XCTAssertEqual(SSAPParsers.screenOff(json(#"{"state":"Screen Saver"}"#)), false)
        XCTAssertEqual(SSAPParsers.screenOff(json(#"{"state":"Active","processing":"Screen Off"}"#)), true)
        XCTAssertEqual(SSAPParsers.screenOff(json(#"{"state":"Screen Off","processing":"Screen On"}"#)), false)
        XCTAssertNil(SSAPParsers.screenOff(json(#"{"state":"Active Standby","processing":"Request Active Standby"}"#)))
        XCTAssertNil(SSAPParsers.screenOff(json(#"{"returnValue":false,"errorText":"404 no such service or method"}"#)))
    }

    func testKeyboard() {
        // webOS 4.5, captured.
        let focus = json(#"{"currentWidget":{"autoCapitalizationEnabled":true,"contentType":"text","cursorPosition":0,"focus":true,"hasSurroundingText":false,"hiddenText":false,"predictionEnabled":true,"surroundingTextLength":0},"focusChanged":true}"#)
        XCTAssertEqual(SSAPParsers.keyboard(focus), KeyboardState(visible: true))
        XCTAssertEqual(SSAPParsers.keyboard(json(#"{"currentWidget":{"focus":false},"subscribed":true}"#)), KeyboardState(visible: false))
        XCTAssertNil(SSAPParsers.keyboard(json(#"{"subscribed":true}"#)))
        XCTAssertEqual(SSAPParsers.keyboard(json(#"{"keyboardVisible":true}"#)), KeyboardState(visible: true))
    }

    func testChannels() {
        let p = json(#"{"channelList":[{"channelId":"1_2_3","channelNumber":"7","channelName":"Das Erste"},{"channelId":"x","channelNumber":12}]}"#)
        XCTAssertEqual(SSAPParsers.channels(p), [TVChannel(id: "1_2_3", number: "7", name: "Das Erste"), TVChannel(id: "x", number: "12", name: "12")])
        XCTAssertNil(SSAPParsers.channel(json(#"{"returnValue":true}"#)))
    }

    func testSoftwareInfoAndVersions() {
        let p = json(#"{"returnValue":true,"product_name":"webOSTV 4.5","model_name":"HE_DTV_W19H_AFADABAA","sw_type":"FIRMWARE","major_ver":"05","minor_ver":"30.40","country":"DE","device_id":"20:17:42:d6:55:d7"}"#)
        let s = SSAPParsers.softwareInfo(p)
        XCTAssertEqual(s.webOSVersion, "4.5")
        XCTAssertEqual(s.firmwareVersion, "05.30.40")
        XCTAssertEqual(SSAPParsers.marketingWebOSVersion(fromProductName: "webOSTV 7.3"), "22")
        XCTAssertEqual(SSAPParsers.marketingWebOSVersion(fromProductName: "webOSTV 10.0"), "25")
        XCTAssertEqual(SSAPParsers.marketingWebOSVersion(fromProductName: "webOS TV 3.5"), "3.5")
        XCTAssertEqual(SSAPParsers.estimatedWebOSVersion(modelName: "55SM8000PLA"), "4.5")
        XCTAssertEqual(SSAPParsers.estimatedWebOSVersion(modelName: "OLED65C1PUB"), "6.0")
        XCTAssertEqual(SSAPParsers.estimatedWebOSVersion(modelName: "OLED55CX6LA"), "5.0")
        XCTAssertEqual(SSAPParsers.estimatedWebOSVersion(modelName: "49LF6300"), "2.0")
        XCTAssertEqual(SSAPParsers.estimatedWebOSVersion(modelName: "43UK6300"), "4.0")
        XCTAssertNil(SSAPParsers.estimatedWebOSVersion(modelName: "65NANO866NA"))
    }

    func testMACsAndDeviceName() {
        let p = json(#"{"P2PInfo":{"macAddress":"46:CB:8B:3D:9E:70"},"wifiInfo":{"macAddress":"44:cb:8b:3d:9e:70"},"wiredInfo":{"macAddress":"20:17:42:D6:55:D7"},"returnValue":true}"#)
        XCTAssertEqual(SSAPParsers.macAddresses(p), ["20:17:42:D6:55:D7", "44:CB:8B:3D:9E:70"])
        XCTAssertEqual(SSAPParsers.macAddresses(json(#"{"wiredInfo":{"macAddress":"00:00:00:00:00:00"}}"#)), [])
        XCTAssertEqual(SSAPParsers.deviceName(json(#"{"settings":{"deviceName":"[LG] webOS TV SM8000PLA"}}"#)), "[LG] webOS TV SM8000PLA")
        XCTAssertNil(SSAPParsers.deviceName(json(#"{"settings":{"deviceName":"  "}}"#)))
    }

    func testResultMapping() {
        func r(_ s: String) -> Result<JSON, LGError> { SSAPEngine.result(of: json(s)) }
        if case .failure(.unsupported) = r(#"{"type":"error","id":"1","error":"404 no such service or method","payload":{}}"#) {} else { XCTFail() }
        if case .failure(.tvError(let m)) = r(#"{"type":"error","id":"1","error":"500 Application error","payload":{"returnValue":false,"errorText":"Some keys are not allowed"}}"#) {
            XCTAssertEqual(m, "500 Application error (Some keys are not allowed)")
        } else { XCTFail() }
        if case .success(let p) = r(#"{"type":"response","id":"1","payload":{"returnValue":true,"x":1}}"#) { XCTAssertEqual(p["x"], 1) } else { XCTFail() }
        XCTAssertTrue(SSAPEngine.isDenial("403 User denied access"))
        XCTAssertTrue(SSAPEngine.isDenial("403 cancelled"))
        XCTAssertFalse(SSAPEngine.isDenial("401 insufficient permissions"))
    }

    func testRegistrationPayload() {
        let p = RegistrationManifest.payload(clientKey: "abc", pin: false)
        XCTAssertEqual(p["client-key"], "abc")
        XCTAssertEqual(p["pairingType"], "PROMPT")
        XCTAssertEqual(p["forcePairing"], false)
        XCTAssertEqual(p["manifest"]?["manifestVersion"], 1)
        XCTAssertTrue(p["manifest"]?["permissions"]?.arrayValue?.contains("CONTROL_INPUT_TEXT") ?? false)
        XCTAssertNil(RegistrationManifest.payload(clientKey: "", pin: true)["client-key"])
        XCTAssertEqual(RegistrationManifest.payload(clientKey: nil, pin: true)["pairingType"], "PIN")
    }
}

final class AppSleepTimerTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 0)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func inc() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    func testWarnsThenFires() async {
        let clock = Clock(), warned = Counter(), fired = Counter()
        let timer = AppSleepTimer(checkInterval: 0.01, now: { clock.now }, warn: { warned.inc() }, fire: { fired.inc() })
        timer.set(minutes: 2)
        XCTAssertEqual(timer.remainingMinutes, 2)
        clock.advance(61)
        do { let ok = await eventually { warned.value == 1 }; XCTAssertTrue(ok) }
        XCTAssertEqual(fired.value, 0)
        clock.advance(60)
        do { let ok = await eventually { fired.value == 1 }; XCTAssertTrue(ok) }
        XCTAssertNil(timer.remainingMinutes)
    }

    func testMissedDeadlineCancelsInsteadOfFiringLate() async throws {
        let clock = Clock(), fired = Counter()
        let timer = AppSleepTimer(checkInterval: 0.01, now: { clock.now }, warn: {}, fire: { fired.inc() })
        timer.set(minutes: 1)
        clock.advance(60 * 60) // app was suspended for an hour
        do { let ok = await eventually { timer.remainingMinutes == nil }; XCTAssertTrue(ok) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fired.value, 0)
    }

    func testDeadlineSurvivesClientReplacement() async {
        let clock = Clock(), fired = Counter(), key = "survive-\(UUID())"
        var first: AppSleepTimer? = AppSleepTimer(key: key, checkInterval: 0.01, now: { clock.now }, warn: {}, fire: {})
        first?.set(minutes: 5)
        first?.suspend(); first = nil // app went to the background; the client is dropped
        let second = AppSleepTimer(key: key, checkInterval: 0.01, now: { clock.now }, warn: {}, fire: { fired.inc() })
        second.resume()
        XCTAssertEqual(second.remainingMinutes, 5)
        clock.advance(5 * 60 + 1)
        let ok = await eventually { fired.value == 1 }
        XCTAssertTrue(ok)
        let third = AppSleepTimer(key: key, checkInterval: 0.01, now: { clock.now }, warn: {}, fire: {})
        third.resume()
        XCTAssertNil(third.remainingMinutes, "a fired timer must not come back")
    }

    func testCancelledDeadlineDoesNotComeBack() {
        let key = "cancel-\(UUID())"
        let first = AppSleepTimer(key: key, warn: {}, fire: {})
        first.set(minutes: 30); first.set(minutes: nil); first.suspend()
        let second = AppSleepTimer(key: key, warn: {}, fire: {})
        second.resume()
        XCTAssertNil(second.remainingMinutes)
    }

    func testCancel() async throws {
        let clock = Clock(), fired = Counter()
        let timer = AppSleepTimer(checkInterval: 0.01, now: { clock.now }, warn: {}, fire: { fired.inc() })
        timer.set(minutes: 1)
        timer.set(minutes: nil)
        clock.advance(61)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fired.value, 0)
        XCTAssertNil(timer.remainingMinutes)
    }
}
