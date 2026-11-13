import Foundation

public struct TouchPoint: Sendable, Hashable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    static func - (a: TouchPoint, b: TouchPoint) -> PointerDelta { PointerDelta(dx: a.x - b.x, dy: a.y - b.y) }
}

/// What the touch surface asks the app to do.
public enum TouchpadAction: Sendable, Hashable {
    /// Finger movement in points over `dt` seconds (raw — apply `PointerAccelerator`).
    case move(PointerDelta, dt: TimeInterval, drag: Bool)
    /// Two-finger movement in points (raw, finger direction).
    case scroll(PointerDelta)
    case click
    /// Quick two-finger tap (mapped to Back).
    case twoFingerTap
    /// Long-press recognised; following moves are drags until `dragEnded`.
    case dragBegan
    case dragEnded
    case scrollBegan
    case scrollEnded
}

/// Laptop-trackpad gesture recognition as a pure state machine, fed with raw touch samples.
///
/// * one finger: moves the cursor immediately; a short, still touch is a click;
///   holding still for `longPressDuration` starts a drag that lasts until the finger lifts
/// * two fingers: moving scrolls; a short, still touch is `twoFingerTap`
/// * a third finger, or fingers left behind after a two-finger gesture, are ignored until all lift
public struct TouchpadInterpreter: Sendable {
    public var tapMaxDuration: TimeInterval = 0.28
    public var twoFingerTapMaxDuration: TimeInterval = 0.35
    public var tapSlop: Double = 10
    public var scrollSlop: Double = 6
    public var longPressDuration: TimeInterval = 0.5

    private enum Phase: Sendable {
        case idle
        case one(id: Int, startTime: TimeInterval, last: TouchPoint, lastTime: TimeInterval, travelled: Double, dragging: Bool)
        case two(startTime: TimeInterval, lastCentroid: TouchPoint, travelled: Double, scrolling: Bool)
        /// Ignore everything until all fingers lift.
        case settling
    }
    private var phase: Phase = .idle
    private var touches: [Int: TouchPoint] = [:]

    public init() {}

    public var activeTouchCount: Int { touches.count }
    public var isDragging: Bool { if case .one(_, _, _, _, _, true) = phase { true } else { false } }

    public mutating func began(id: Int, at p: TouchPoint, time: TimeInterval) -> [TouchpadAction] {
        touches[id] = p
        switch phase {
        case .idle:
            phase = .one(id: id, startTime: time, last: p, lastTime: time, travelled: 0, dragging: false)
            return []
        case .one(_, _, _, _, _, let dragging):
            if dragging || touches.count != 2 { return [] }
            phase = .two(startTime: time, lastCentroid: centroid(), travelled: 0, scrolling: false)
            return []
        case .two(_, _, _, let scrolling):
            phase = .settling
            return scrolling ? [.scrollEnded] : []
        case .settling:
            return []
        }
    }

    public mutating func moved(id: Int, to p: TouchPoint, time: TimeInterval) -> [TouchpadAction] {
        guard touches[id] != nil else { return [] }
        touches[id] = p
        switch phase {
        case let .one(oid, start, last, lastTime, travelled, dragging) where oid == id:
            let d = p - last
            guard !d.isZero else { return [] }
            phase = .one(id: oid, startTime: start, last: p, lastTime: time, travelled: travelled + d.magnitude, dragging: dragging)
            return [.move(d, dt: time - lastTime, drag: dragging)]
        case let .two(start, lastCentroid, travelled, scrolling):
            let c = centroid()
            let d = c - lastCentroid
            guard !d.isZero else { return [] }
            let total = travelled + d.magnitude
            var out: [TouchpadAction] = []
            var nowScrolling = scrolling
            if !scrolling && total > scrollSlop { nowScrolling = true; out.append(.scrollBegan) }
            if nowScrolling { out.append(.scroll(d)) }
            phase = .two(startTime: start, lastCentroid: c, travelled: total, scrolling: nowScrolling)
            return out
        default:
            return []
        }
    }

    public mutating func ended(id: Int, time: TimeInterval, cancelled: Bool = false) -> [TouchpadAction] {
        guard touches.removeValue(forKey: id) != nil else { return [] }
        switch phase {
        case let .one(oid, start, _, _, travelled, dragging) where oid == id:
            phase = touches.isEmpty ? .idle : .settling
            if dragging { return [.dragEnded] }
            if !cancelled && time - start <= tapMaxDuration && travelled < tapSlop { return [.click] }
            return []
        case let .two(start, _, travelled, scrolling):
            phase = touches.isEmpty ? .idle : .settling
            if scrolling { return [.scrollEnded] }
            if !cancelled && time - start <= twoFingerTapMaxDuration && travelled < tapSlop { return [.twoFingerTap] }
            return []
        default:
            if touches.isEmpty { phase = .idle }
            return []
        }
    }

    /// Call periodically (e.g. every frame) while touches are down; recognises long-press drags.
    public mutating func tick(time: TimeInterval) -> [TouchpadAction] {
        guard case let .one(id, start, last, lastTime, travelled, false) = phase,
              travelled < tapSlop, time - start >= longPressDuration else { return [] }
        phase = .one(id: id, startTime: start, last: last, lastTime: lastTime, travelled: travelled, dragging: true)
        return [.dragBegan]
    }

    /// Drops all touches (e.g. the view disappeared mid-gesture).
    public mutating func reset() -> [TouchpadAction] {
        defer { phase = .idle; touches.removeAll() }
        switch phase {
        case .one(_, _, _, _, _, true): return [.dragEnded]
        case .two(_, _, _, true): return [.scrollEnded]
        default: return []
        }
    }

    private func centroid() -> TouchPoint {
        guard !touches.isEmpty else { return TouchPoint(x: 0, y: 0) }
        let n = Double(touches.count)
        return TouchPoint(x: touches.values.reduce(0) { $0 + $1.x } / n, y: touches.values.reduce(0) { $0 + $1.y } / n)
    }
}
