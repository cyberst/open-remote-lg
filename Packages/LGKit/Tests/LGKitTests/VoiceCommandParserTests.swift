import XCTest
@testable import LGKit

final class VoiceCommandParserTests: XCTestCase {
    let parser = VoiceCommandParser()

    private func check(_ cases: [(String, VoiceIntent)], file: StaticString = #filePath, line: UInt = #line) {
        for (transcript, expected) in cases {
            XCTAssertEqual(parser.parse(transcript), expected, "“\(transcript)”", file: file, line: line)
        }
    }

    func testVolume() {
        check([
            ("volume up", .volumeUp(by: 1)),
            ("Volume up.", .volumeUp(by: 1)),
            ("turn it up", .volumeUp(by: 1)),
            ("turn the volume up", .volumeUp(by: 1)),
            ("louder", .volumeUp(by: 1)),
            ("louder please", .volumeUp(by: 1)),
            ("increase the volume by 5", .volumeUp(by: 5)),
            ("volume up by five", .volumeUp(by: 5)),
            ("raise volume by twenty five", .volumeUp(by: 25)),
            ("volume up 3", .volumeUp(by: 3)),
            ("turn up the volume a lot", .volumeUp(by: 10)),
            ("volume down", .volumeDown(by: 1)),
            ("quieter", .volumeDown(by: 1)),
            ("turn it down", .volumeDown(by: 1)),
            ("turn the TV down", .volumeDown(by: 1)),
            ("lower the volume by 4", .volumeDown(by: 4)),
            ("decrease volume by ten", .volumeDown(by: 10)),
            ("Hey TV, can you make it softer please?", .volumeDown(by: 1)),
            ("set volume to 12", .setVolume(12)),
            ("volume 12", .setVolume(12)),
            ("Volume twelve", .setVolume(12)),
            ("set the volume to twenty five", .setVolume(25)),
            ("change volume to 7", .setVolume(7)),
            ("volume at 30%", .setVolume(30)),
            ("turn the volume down to 5", .setVolume(5)),
            ("set volume to 250", .setVolume(100)),
            ("volume to one hundred", .setVolume(100)),
            ("volume zero", .setVolume(0)),
        ])
    }

    func testMute() {
        check([
            ("mute", .mute),
            ("Mute the TV.", .mute),
            ("please mute", .mute),
            ("sound off", .mute),
            ("be quiet", .mute),
            ("silence", .mute),
            ("unmute", .unmute),
            ("Unmute the TV please", .unmute),
            ("un mute", .unmute),
            ("sound on", .unmute),
            ("turn the sound back on", .unmute),
            ("turn off mute", .unmute),
        ])
    }

    func testChannels() {
        check([
            ("channel up", .channelUp),
            ("next channel", .channelUp),
            ("channel down", .channelDown),
            ("previous channel", .channelDown),
            ("channel 5", .channel("5")),
            ("channel five", .channel("5")),
            ("Channel five.", .channel("5")),
            ("go to channel 12", .channel("12")),
            ("switch to channel twenty two", .channel("22")),
            ("change the channel to 7", .channel("7")),
            ("put on channel number 9", .channel("9")),
            ("channel 5-1", .channel("5-1")),
            ("channel 5.1", .channel("5-1")),
            ("channel five dash one", .channel("5-1")),
            ("channel one two three", .channel("123")),
            ("channel one hundred and one", .channel("101")),
            ("watch channel BBC One", .channel("bbc 1")),
        ])
    }

    func testApps() {
        check([
            ("open Netflix", .openApp("netflix")),
            ("Open YouTube.", .openApp("youtube")),
            ("launch the YouTube app", .openApp("youtube")),
            ("start Prime Video", .openApp("prime video")),
            ("open amazon", .openApp("amazon")),
            ("open Disney+", .openApp("disney plus")),
            ("open disney plus", .openApp("disney plus")),
            ("open Apple TV", .openApp("apple tv")),
            ("launch spotify please", .openApp("spotify")),
            ("go to live TV", .openApp("live tv")),
            ("open the browser", .openApp("browser")),
            ("hey tv open netflix", .openApp("netflix")),
            ("can you open netflix for me", .openApp("netflix")),
            ("I want to watch Netflix", .openApp("netflix")),
            ("switch to PlayStation", .openApp("playstation")),
            ("open netflix on the tv", .openApp("netflix")),
            ("turn on netflix", .openApp("netflix")),
            ("fire up plex", .openApp("plex")),
        ])
    }

    func testInputs() {
        check([
            ("switch to HDMI 2", .switchInput(.hdmi(2))),
            ("HDMI two", .switchInput(.hdmi(2))),
            ("hdmi2", .switchInput(.hdmi(2))),
            ("change input to HDMI 1", .switchInput(.hdmi(1))),
            ("go to hdmi to", .switchInput(.hdmi(2))),
            ("switch input to PlayStation", .switchInput(.named("playstation"))),
            ("change the source to xbox", .switchInput(.named("xbox"))),
            ("input 3", .switchInput(.hdmi(3))),
            ("input AV", .switchInput(.named("av"))),
        ])
    }

    func testNavigation() {
        check([
            ("home", .key(.home)),
            ("go home", .key(.home)),
            ("Go home!", .key(.home)),
            ("open home", .key(.home)),
            ("back", .key(.back)),
            ("go back", .key(.back)),
            ("ok", .key(.enter)),
            ("OK.", .key(.enter)),
            ("okay", .key(.enter)),
            ("select", .key(.enter)),
            ("press ok", .key(.enter)),
            ("enter", .key(.enter)),
            ("click", .key(.enter)),
            ("up", .key(.up)),
            ("down", .key(.down)),
            ("move left", .key(.left)),
            ("go right", .key(.right)),
            ("down three times", .key(.down, times: 3)),
            ("move down 3", .key(.down, times: 3)),
            ("left twice", .key(.left, times: 2)),
            ("right 50 times", .key(.right, times: 20)),
            ("press the up button", .key(.up)),
            ("exit", .key(.exit)),
            ("settings", .key(.menu)),
            ("open settings", .key(.menu)),
            ("quick settings", .key(.qMenu)),
            ("info", .key(.info)),
            ("show info", .key(.info)),
            ("guide", .key(.guide)),
            ("tv guide", .key(.guide)),
            ("press the red button", .key(.red)),
        ])
    }

    func testPlayback() {
        check([
            ("play", .media(.play)),
            ("Play.", .media(.play)),
            ("resume", .media(.play)),
            ("pause", .media(.pause)),
            ("pause it", .media(.pause)),
            ("pause the video", .media(.pause)),
            ("stop", .media(.stop)),
            ("rewind", .media(.rewind)),
            ("fast forward", .media(.fastForward)),
            ("fast-forward", .media(.fastForward)),
            ("skip ahead", .media(.fastForward)),
            ("press play", .media(.play)),
        ])
    }

    func testScreenAndPower() {
        check([
            ("screen off", .screenOff),
            ("turn off the screen", .screenOff),
            ("turn the screen off", .screenOff),
            ("blank the screen", .screenOff),
            ("turn the picture off", .screenOff),
            ("screen on", .screenOn),
            ("turn the screen back on", .screenOn),
            ("turn off the TV", .powerOff),
            ("Turn off the TV.", .powerOff),
            ("turn the tv off", .powerOff),
            ("power off", .powerOff),
            ("switch off", .powerOff),
            ("TV off", .powerOff),
            ("shut down the television", .powerOff),
            ("hey tv turn off", .powerOff),
            ("turn the power off", .powerOff),
            ("good night", .powerOff),
            ("turn on the tv", .powerOn),
        ])
    }

    func testSleepTimer() {
        check([
            ("sleep timer 30 minutes", .sleepTimer(minutes: 30)),
            ("set a sleep timer for thirty minutes", .sleepTimer(minutes: 30)),
            ("sleep in 45 minutes", .sleepTimer(minutes: 45)),
            ("sleep timer 1 hour", .sleepTimer(minutes: 60)),
            ("sleep timer two hours", .sleepTimer(minutes: 120)),
            ("set the sleep timer for an hour", .sleepTimer(minutes: 60)),
            ("sleep timer half an hour", .sleepTimer(minutes: 30)),
            ("sleep timer one and a half hours", .sleepTimer(minutes: 90)),
            ("sleep timer an hour and a half", .sleepTimer(minutes: 90)),
            ("sleep timer 1 hour 15 minutes", .sleepTimer(minutes: 75)),
            ("sleep timer 20", .sleepTimer(minutes: 20)),
            ("turn off in 30 minutes", .sleepTimer(minutes: 30)),
            ("turn the TV off in an hour", .sleepTimer(minutes: 60)),
            ("turn off the tv after 90 minutes", .sleepTimer(minutes: 90)),
            ("cancel the sleep timer", .cancelSleepTimer),
            ("sleep timer off", .cancelSleepTimer),
            ("turn off the sleep timer", .cancelSleepTimer),
            ("stop sleep timer", .cancelSleepTimer),
            ("no sleep timer", .cancelSleepTimer),
        ])
    }

    func testTypeAndSearch() {
        check([
            ("type hello world", .type("hello world")),
            ("Type Hello World.", .type("Hello World")),
            ("type in my password", .type("my password")),
            ("please type The Office", .type("The Office")),
            ("type turn off the tv", .type("turn off the tv")),
            ("type twenty five", .type("twenty five")),
            ("write Breaking Bad", .type("Breaking Bad")),
            ("search for cat videos", .search("cat videos", app: nil)),
            ("Search for The Office.", .search("The Office", app: nil)),
            ("search Stranger Things", .search("Stranger Things", app: nil)),
            ("search youtube for lofi music", .search("lofi music", app: "youtube")),
            ("search for lofi music on YouTube", .search("lofi music", app: "youtube")),
            ("search on youtube for cooking", .search("cooking", app: "youtube")),
            ("play lofi beats on youtube", .search("lofi beats", app: "youtube")),
            ("find The Crown on Netflix", .search("The Crown", app: "netflix")),
            ("look up pasta recipes", .search("pasta recipes", app: nil)),
            ("show me videos of cats", .search("cats", app: "youtube")),
            ("search", .search("", app: nil)),
        ])
    }

    func testFillerAndUnknown() {
        check([
            ("Hey TV, please go home.", .key(.home)),
            ("okay tv mute", .mute),
            ("could you please pause", .media(.pause)),
            ("would you please pause", .media(.pause)),
            ("um volume up", .volumeUp(by: 1)),
            ("mute thanks", .mute),
            ("OPEN NETFLIX!!!", .openApp("netflix")),
        ])
        XCTAssertEqual(parser.parse(""), .unknown(""))
        XCTAssertEqual(parser.parse("   "), .unknown("   "))
        XCTAssertEqual(parser.parse("what's the weather like"), .unknown("what's the weather like"))
        XCTAssertEqual(parser.parse("banana"), .unknown("banana"))
        XCTAssertEqual(parser.parse("please"), .unknown("please"))
    }

    func testNumberWords() {
        func n(_ s: String) -> [String] { EnglishNumbers.collapse(VoiceTokenizer.tokenize(s)).map(\.word) }
        XCTAssertEqual(n("twenty five"), ["25"])
        XCTAssertEqual(n("twenty-five"), ["25"])
        XCTAssertEqual(n("one hundred and five"), ["105"])
        XCTAssertEqual(n("a hundred"), ["100"])
        XCTAssertEqual(n("ninety nine"), ["99"])
        XCTAssertEqual(n("five one"), ["5", "1"])
        XCTAssertEqual(n("twelve thirteen"), ["12", "13"])
        XCTAssertEqual(n("rock and roll"), ["rock", "and", "roll"])
        XCTAssertEqual(n("one hundred and"), ["100", "and"])
    }

    func testLanguageSupport() {
        XCTAssertTrue(VoiceCommandParser.supports(Locale(identifier: "en_US")))
        XCTAssertTrue(VoiceCommandParser.supports(Locale(identifier: "en_GB")))
        XCTAssertFalse(VoiceCommandParser.supports(Locale(identifier: "de_DE")))
    }
}
