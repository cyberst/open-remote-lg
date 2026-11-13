import Foundation

/// A pointer-socket message ready to send.
public enum PointerCommand: Sendable, Hashable {
    case move(dx: Double, dy: Double, drag: Bool)
    case scroll(dx: Double, dy: Double)
    case click
}

/// Rate-limits and coalesces pointer traffic so the TV never falls behind the finger.
///
/// Consecutive moves (with the same drag flag) and consecutive scrolls are merged into one pending
/// message instead of queueing up, continuous messages go out at most once per `interval`, and a
/// continuous message that has waited longer than `staleAfter` (e.g. the socket stalled) is dropped
/// rather than delivered late as a sudden jump. Clicks are never merged or dropped and keep their
/// order relative to movement, so a click always lands where the cursor was when the user tapped.
public struct PointerEventQueue: Sendable {
    public var interval: TimeInterval
    public var staleAfter: TimeInterval

    private struct Item: Sendable {
        var command: PointerCommand
        var enqueued: TimeInterval
    }
    private var items: [Item] = []
    private var lastContinuousSend: TimeInterval = -.infinity
    private var lastMoveWasDrag = false

    public init(interval: TimeInterval = 1.0 / 60, staleAfter: TimeInterval = 0.35) {
        self.interval = interval; self.staleAfter = staleAfter
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func enqueue(_ command: PointerCommand, now: TimeInterval) {
        if case let .move(dx, dy, drag) = command {
            // A zero move is meaningless, except a plain move right after dragging: it releases the drag.
            if dx == 0 && dy == 0 && !(lastMoveWasDrag && !drag) { return }
            lastMoveWasDrag = drag
        }
        if case .scroll(0, 0) = command { return }
        if let last = items.last, let merged = Self.merge(last.command, command) {
            // Keep the original timestamp: staleness is about how long the oldest movement has waited.
            items[items.count - 1].command = merged
        } else {
            items.append(Item(command: command, enqueued: now))
        }
    }

    /// When the next command may be sent, or nil if nothing is pending.
    public func nextSendTime() -> TimeInterval? {
        guard let first = items.first else { return nil }
        if case .click = first.command { return first.enqueued }
        return max(first.enqueued, lastContinuousSend + interval)
    }

    /// Pops the next command that may be sent at `now`, discarding stale movement.
    public mutating func dequeue(now: TimeInterval) -> PointerCommand? {
        while let first = items.first {
            if case .click = first.command { items.removeFirst(); return .click }
            if now - first.enqueued > staleAfter && !Self.isRelease(first.command) { items.removeFirst(); continue }
            guard now - lastContinuousSend >= interval else { return nil }
            items.removeFirst()
            lastContinuousSend = now
            return first.command
        }
        return nil
    }

    /// Drops everything pending except drag releases, so the TV is never left "holding" the button.
    public mutating func removeAll() { items.removeAll { !Self.isRelease($0.command) } }

    /// A zero-length plain move: sent after a drag to release it. Never merged, never dropped as stale.
    static func isRelease(_ c: PointerCommand) -> Bool {
        if case .move(0, 0, false) = c { true } else { false }
    }

    static func merge(_ a: PointerCommand, _ b: PointerCommand) -> PointerCommand? {
        if isRelease(a) || isRelease(b) { return nil }
        return switch (a, b) {
        case let (.move(ax, ay, ad), .move(bx, by, bd)) where ad == bd: .move(dx: ax + bx, dy: ay + by, drag: ad)
        case let (.scroll(ax, ay), .scroll(bx, by)): .scroll(dx: ax + bx, dy: ay + by)
        default: nil
        }
    }
}
