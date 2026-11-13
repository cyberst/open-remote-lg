import XCTest
@testable import LGKit

final class VoiceCommandExecutorTests: XCTestCase {
    private func make() -> (MockTV, VoiceCommandExecutor) {
        let tv = MockTV()
        return (tv, VoiceCommandExecutor(tv: tv, repeatDelay: .zero))
    }

    func testVolume() async throws {
        let (tv, ex) = make()
        // MockTV starts at volume 3.
        var msg = try await ex.execute(.volumeUp(by: 1))
        XCTAssertEqual(msg, "Volume 4")
        msg = try await ex.execute(.volumeUp(by: 5))
        XCTAssertEqual(msg, "Volume 9")
        msg = try await ex.execute(.volumeDown(by: 50))
        XCTAssertEqual(msg, "Volume 0")
        msg = try await ex.execute(.setVolume(140))
        XCTAssertEqual(msg, "Volume 100")
        msg = try await ex.execute(.setVolume(-3))
        XCTAssertEqual(msg, "Volume 0")
        let v = try await tv.volume()
        XCTAssertEqual(v.volume, 0)
        msg = try await ex.execute(.mute)
        XCTAssertEqual(msg, "Muted")
        let muted = try await tv.volume().muted
        XCTAssertTrue(muted)
        msg = try await ex.execute(.unmute)
        XCTAssertEqual(msg, "Sound on")
    }

    func testOpenAppsViaAliases() async throws {
        let (tv, ex) = make()
        let cases: [(String, String, String)] = [
            ("netflix", "netflix", "Opening Netflix"),
            ("youtube", "youtube.leanback.v4", "Opening YouTube"),
            ("you tube", "youtube.leanback.v4", "Opening YouTube"),
            ("prime", "amazon", "Opening Prime Video"),
            ("amazon prime", "amazon", "Opening Prime Video"),
            ("disney plus", "com.disney.disneyplus-prod", "Opening Disney+"),
            ("apple tv", "com.apple.appletv", "Opening Apple TV"),
            ("spotify", "spotify-beehive", "Opening Spotify"),
            ("live tv", "com.webos.app.livetv", "Opening Live TV"),
            ("browser", "com.webos.app.browser", "Opening Web Browser"),
            ("photo and video", "com.webos.app.photovideo", "Opening Photo & Video"),
            ("netflicks", "netflix", "Opening Netflix"),
        ]
        for (spoken, id, message) in cases {
            let msg = try await ex.execute(.openApp(spoken))
            XCTAssertEqual(msg, message, spoken)
            XCTAssertEqual(tv.log.last, "launch \(id)", spoken)
        }
    }

    func testOpenResolvesInputsAndErrors() async throws {
        let (tv, ex) = make()
        let msg = try await ex.execute(.openApp("playstation"))
        XCTAssertEqual(msg, "Switching to PlayStation")
        XCTAssertEqual(tv.log.last, "input HDMI_2")

        do { _ = try await ex.execute(.openApp("hulu")); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? VoiceCommandError, .appNotInstalled("Hulu")) }
        do { _ = try await ex.execute(.openApp("zzz qqq")); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? VoiceCommandError, .appNotFound("Zzz Qqq")) }
    }

    func testInputs() async throws {
        let (tv, ex) = make()
        var msg = try await ex.execute(.switchInput(.hdmi(1)))
        XCTAssertEqual(msg, "Switching to HDMI 1")
        XCTAssertEqual(tv.log.last, "input HDMI_1")
        msg = try await ex.execute(.switchInput(.hdmi(2)))
        XCTAssertEqual(msg, "Switching to HDMI 2 · PlayStation")
        msg = try await ex.execute(.switchInput(.named("playstation")))
        XCTAssertEqual(msg, "Switching to PlayStation")
        msg = try await ex.execute(.switchInput(.named("av")))
        XCTAssertEqual(tv.log.last, "input AV_1")
        do { _ = try await ex.execute(.switchInput(.hdmi(9))); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? VoiceCommandError, .inputNotFound("HDMI 9")) }
    }

    func testChannels() async throws {
        let (tv, ex) = make()
        var msg = try await ex.execute(.channel("5"))
        XCTAssertEqual(msg, "Channel 5")
        XCTAssertEqual(tv.log.last, "channel ch5")
        msg = try await ex.execute(.channel("channel 7"))
        XCTAssertEqual(tv.log.last, "channel ch7")
        msg = try await ex.execute(.channelUp)
        XCTAssertEqual(tv.log.last, "channelUp")
        // Not in the list: falls back to typing digits on Live TV.
        msg = try await ex.execute(.channel("5-1"))
        XCTAssertEqual(msg, "Channel 5-1")
        XCTAssertEqual(Array(tv.log.suffix(4)), ["press 5", "press DASH", "press 1", "press ENTER"])
        do { _ = try await ex.execute(.channel("nonexistent")); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? VoiceCommandError, .channelNotFound("nonexistent")) }
    }

    func testKeysMediaSystem() async throws {
        let (tv, ex) = make()
        var msg = try await ex.execute(.key(.down, times: 3))
        XCTAssertEqual(msg, "Down × 3")
        XCTAssertEqual(tv.log.suffix(3), ["press DOWN", "press DOWN", "press DOWN"])
        msg = try await ex.execute(.key(.enter))
        XCTAssertEqual(msg, "OK")
        msg = try await ex.execute(.media(.pause))
        XCTAssertEqual(msg, "Paused")
        XCTAssertEqual(tv.log.last, "media pause")
        msg = try await ex.execute(.screenOff)
        XCTAssertEqual(tv.log.last, "screenOff")
        msg = try await ex.execute(.screenOn)
        XCTAssertEqual(tv.log.last, "screenOn")
        msg = try await ex.execute(.sleepTimer(minutes: 90))
        XCTAssertEqual(msg, "Sleep timer: 1 h 30 min")
        XCTAssertEqual(tv.log.last, "sleep 90")
        let remaining = await tv.sleepTimerRemaining()
        XCTAssertEqual(remaining, 90)
        msg = try await ex.execute(.cancelSleepTimer)
        XCTAssertEqual(msg, "Sleep timer off")
        XCTAssertEqual(tv.log.last, "sleep 0")
        msg = try await ex.execute(.powerOff)
        XCTAssertEqual(msg, "Turning off the TV")
        XCTAssertEqual(tv.log.last, "powerOff")
    }

    func testTypeAndSearch() async throws {
        let (tv, ex) = make()
        var msg = try await ex.execute(.type("Hello"))
        XCTAssertEqual(msg, "Typed “Hello”")
        XCTAssertEqual(tv.log.last, "text Hello replace=false")

        msg = try await ex.execute(.search("lofi beats", app: nil))
        XCTAssertEqual(msg, "Searching YouTube for “lofi beats”")
        XCTAssertEqual(tv.log.last, "launch youtube.leanback.v4")

        msg = try await ex.execute(.search("pasta", app: "browser"))
        XCTAssertEqual(msg, "Searching the web for “pasta”")
        XCTAssertEqual(tv.log.last, "browser https://duckduckgo.com/?q=pasta")

        msg = try await ex.execute(.search("The Crown", app: "netflix"))
        XCTAssertEqual(msg, "Opening Netflix")

        msg = try await ex.execute(.search("", app: nil))
        XCTAssertEqual(tv.log.last, "press SEARCH")
    }

    func testSearchParams() {
        let p = VoiceCommandExecutor.youTubeSearchParams("cats & dogs")
        XCTAssertEqual(p["contentTarget"]?.stringValue, "https://www.youtube.com/tv?launch=voice&vq=cats%20%26%20dogs")
    }

    func testUnknownThrows() async {
        let (_, ex) = make()
        do { _ = try await ex.run("what's the weather"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? VoiceCommandError, .notUnderstood("what's the weather")) }
    }

    func testEndToEnd() async throws {
        let (tv, ex) = make()
        let (intent, msg) = try await ex.run("Hey TV, open Netflix please")
        XCTAssertEqual(intent, .openApp("netflix"))
        XCTAssertEqual(msg, "Opening Netflix")
        XCTAssertEqual(tv.log.last, "launch netflix")
    }

    func testMatcher() {
        XCTAssertGreaterThan(VoiceNameMatcher.score("disney plus", "Disney+"), 0.95)
        XCTAssertGreaterThan(VoiceNameMatcher.score("photo", "Photo & Video"), 0.75)
        XCTAssertLessThan(VoiceNameMatcher.score("netflix", "Spotify"), 0.75)
        XCTAssertEqual(VoiceNameMatcher.canonicalChannelNumber("05.1"), "5-1")
        XCTAssertEqual(VoiceCommandExecutor.formatMinutes(45), "45 min")
        XCTAssertEqual(VoiceCommandExecutor.formatMinutes(120), "2 h")
    }
}
