import Foundation

/// Keeps a phone text field and the TV's focused text field in sync.
///
/// `tvText` is what we believe the TV field contains. Local edits become IME ops via `TextDiff`;
/// TV-side changes (the user focused another field, or the TV app changed the text) are adopted into
/// the phone field only when the user isn't mid-typing, so echoes of our own edits never fight the user.
public struct TextMirror: Sendable {
    public private(set) var tvText: String = ""
    public private(set) var tvFieldActive = false
    /// How long after the last local edit TV-reported text may overwrite the phone field.
    public var quietPeriod: TimeInterval
    private var lastLocalEdit: TimeInterval = -.infinity
    private var tvTextKnown = true

    public init(quietPeriod: TimeInterval = 0.8) { self.quietPeriod = quietPeriod }

    /// The user changed the phone field; returns the ops that bring the TV field to `text`.
    public mutating func localChanged(to text: String, now: TimeInterval) -> [TextEditOp] {
        lastLocalEdit = now
        if !tvTextKnown {
            tvTextKnown = true
            tvText = text
            return [.replace(text)]
        }
        let ops = TextDiff.ops(from: tvText, to: text)
        tvText = text
        return ops
    }

    /// A send failed, so the TV's contents are uncertain; the next local change rewrites the whole field.
    public mutating func markOutOfSync() { tvTextKnown = false }

    /// Feed `observeKeyboard()` updates. Returns text to put into the phone field, or nil to leave it alone.
    public mutating func tvReported(_ state: KeyboardState, localText: String, now: TimeInterval) -> String? {
        let becameActive = state.visible && !tvFieldActive
        tvFieldActive = state.visible
        guard state.visible, let reported = state.currentText else { return nil }
        if becameActive || (reported != tvText && now - lastLocalEdit >= quietPeriod) {
            tvText = reported
            tvTextKnown = true
            return reported == localText ? nil : reported
        }
        return nil
    }
}
