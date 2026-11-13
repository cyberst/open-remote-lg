import Foundation

/// What a spoken command asks the TV to do. Produced by `VoiceCommandParser`, run by `VoiceCommandExecutor`.
public enum VoiceIntent: Sendable, Hashable {
    // Audio
    case volumeUp(by: Int)
    case volumeDown(by: Int)
    case setVolume(Int)
    case mute
    case unmute

    // Channels
    case channelUp
    case channelDown
    /// A channel number ("12", "5-1") or a channel name ("bbc one").
    case channel(String)

    // Apps & inputs
    /// A spoken app (or input) name, lowercased, e.g. "netflix", "disney plus", "playstation".
    case openApp(String)
    case switchInput(InputTarget)

    // Navigation & playback
    case key(RemoteKey, times: Int)
    case media(MediaControl)

    // System
    case screenOff
    case screenOn
    case powerOff
    case powerOn
    case sleepTimer(minutes: Int)
    case cancelSleepTimer

    // Text
    /// Text to type into the TV's active text field, with the speaker's original casing.
    case type(String)
    /// Search for `query`, optionally in a named app ("youtube"). An empty query opens search.
    case search(String, app: String?)

    /// The transcript could not be understood.
    case unknown(String)

    /// Shorthand for a single key press.
    public static func key(_ key: RemoteKey) -> VoiceIntent { .key(key, times: 1) }
}

public enum InputTarget: Sendable, Hashable {
    case hdmi(Int)
    /// A user-visible input label such as "playstation" or "av".
    case named(String)
}
