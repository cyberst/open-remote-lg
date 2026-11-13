import Foundation

/// One edit to apply to the TV's focused text field through the IME API.
public enum TextEditOp: Sendable, Hashable {
    /// Delete this many characters before the TV's caret (`deleteCharacters`).
    case delete(Int)
    /// Insert at the TV's caret (`insertText(replace: false)`).
    case insert(String)
    /// Replace the whole field (`insertText(replace: true)`).
    case replace(String)
}

/// Turns "the TV field contains `old`, the phone field now contains `new`" into the cheapest IME ops.
///
/// The TV IME can only append or delete at its caret (assumed at the end) or replace everything, so
/// edits in the middle are expressed as "delete back to the first difference, then re-type the tail",
/// unless rewriting the whole field is cheaper.
///
/// Deletion counts are in user-perceived characters. Because TVs disagree about how many "characters"
/// an emoji or other non-BMP character is, any deletion that would cross one falls back to `replace`.
public enum TextDiff {
    public static func ops(from old: String, to new: String) -> [TextEditOp] {
        if old == new { return [] }
        if new.isEmpty { return deletionIsUnambiguous(old[...]) ? [.delete(old.count)] : [.replace("")] }

        let prefix = commonPrefixEnd(old, new)
        let removed = old[prefix.old...]
        let added = String(new[prefix.new...])

        if removed.isEmpty { return [.insert(added)] }

        let removeCount = removed.count
        guard deletionIsUnambiguous(removed) else { return [.replace(new)] }
        // Cost in characters sent/deleted; a full rewrite is preferred only when clearly cheaper.
        let incremental = removeCount + added.count
        if incremental > new.count + 2 { return [.replace(new)] }
        return added.isEmpty ? [.delete(removeCount)] : [.delete(removeCount), .insert(added)]
    }

    /// End indices (in `old` and `new`) of the longest common prefix, compared by Character.
    static func commonPrefixEnd(_ a: String, _ b: String) -> (old: String.Index, new: String.Index) {
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            i = a.index(after: i); j = b.index(after: j)
        }
        return (i, j)
    }

    /// True when every character in `s` is a single UTF-16 unit, so "N characters" means the same to everyone.
    static func deletionIsUnambiguous(_ s: Substring) -> Bool {
        s.allSatisfy { $0.utf16.count == 1 }
    }
}
