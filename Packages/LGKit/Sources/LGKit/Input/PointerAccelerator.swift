import Foundation

/// A 2-D delta in points (touch) or TV pixels (output).
public struct PointerDelta: Sendable, Hashable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
    public static let zero = PointerDelta(dx: 0, dy: 0)
    public var isZero: Bool { dx == 0 && dy == 0 }
    public var magnitude: Double { (dx * dx + dy * dy).squareRoot() }
}

/// Carries the fractional part of deltas between calls so slow movements still add up to whole pixels.
public struct RemainderCarry: Sendable, Hashable {
    private var rx = 0.0, ry = 0.0
    public init() {}

    /// Adds `delta` and returns the whole-pixel part; the fraction is kept for next time.
    public mutating func take(_ delta: PointerDelta) -> PointerDelta {
        rx += delta.dx; ry += delta.dy
        let ox = rx.rounded(.towardZero), oy = ry.rounded(.towardZero)
        rx -= ox; ry -= oy
        return PointerDelta(dx: ox, dy: oy)
    }

    public mutating func reset() { rx = 0; ry = 0 }
}

/// Trackpad-style pointer ballistics: slow finger movement maps ~1:1 for precision, fast flicks
/// cover the whole TV screen. Output is whole TV pixels with sub-pixel remainder carry.
public struct PointerAccelerator: Sendable {
    public struct Curve: Sendable, Hashable {
        /// Gain at or below `slowSpeed` (points per second).
        public var minGain: Double
        /// Gain at or above `fastSpeed`.
        public var maxGain: Double
        public var slowSpeed: Double
        public var fastSpeed: Double
        public init(minGain: Double, maxGain: Double, slowSpeed: Double, fastSpeed: Double) {
            self.minGain = minGain; self.maxGain = maxGain; self.slowSpeed = slowSpeed; self.fastSpeed = fastSpeed
        }
        /// Tuned for a phone-sized pad driving a 1920×1080 webOS cursor.
        public static let standard = Curve(minGain: 1.2, maxGain: 4.0, slowSpeed: 60, fastSpeed: 1400)
    }

    public var curve: Curve
    /// User multiplier, typically 0.5…2.0.
    public var sensitivity: Double
    private var carry = RemainderCarry()

    public init(curve: Curve = .standard, sensitivity: Double = 1) {
        self.curve = curve; self.sensitivity = sensitivity
    }

    /// Gain for a finger speed in points per second (smoothstep between the slow and fast speeds).
    public func gain(forSpeed speed: Double) -> Double {
        let span = max(curve.fastSpeed - curve.slowSpeed, 1)
        let t = min(max((speed - curve.slowSpeed) / span, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return (curve.minGain + (curve.maxGain - curve.minGain) * eased) * max(sensitivity, 0.05)
    }

    /// Converts a finger delta (points) over `dt` seconds into whole TV pixels.
    public mutating func process(_ delta: PointerDelta, dt: TimeInterval) -> PointerDelta {
        guard !delta.isZero else { return .zero }
        // Clamp dt: touch timestamps can repeat (dt 0) or arrive after a pause (huge dt).
        let speed = delta.magnitude / min(max(dt, 1.0 / 240), 0.1)
        let g = gain(forSpeed: speed)
        return carry.take(PointerDelta(dx: delta.dx * g, dy: delta.dy * g))
    }

    /// Call when a gesture ends so leftovers don't leak into the next one.
    public mutating func reset() { carry.reset() }
}
