import Foundation

/// A plain 3-vector so motion math is testable without CoreMotion.
public struct Vector3: Sendable, Hashable {
    public var x, y, z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vector3(x: 0, y: 0, z: 0)
    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vector3? {
        let l = length
        return l > 1e-6 ? Vector3(x: x / l, y: y / l, z: z / l) : nil
    }
}

/// Turns gyroscope readings into pointer deltas for "point the phone at the TV" control.
///
/// Horizontal movement comes from rotation about the world's vertical axis (from gravity), so it
/// works whether the phone is held flat like a remote or upright. Vertical movement comes from rotation
/// about the device's x axis (tilting the top edge up/down). A soft dead zone removes hand tremor and
/// gyro noise, an exponential moving average smooths jitter, and fractional pixels are carried over.
public struct MotionToPointer: Sendable {
    /// TV pixels per radian of rotation at sensitivity 1 (≈ a 35° sweep crosses a 1920 px screen).
    public var pixelsPerRadian: Double
    public var sensitivity: Double
    /// Angular speed (rad/s) that is ignored entirely; speeds above it are reduced by this amount.
    public var deadZone: Double
    /// EMA factor in 0…1; 1 = no smoothing.
    public var smoothing: Double

    private var filtered = (yaw: 0.0, pitch: 0.0)
    private var carry = RemainderCarry()

    public init(pixelsPerRadian: Double = 3200, sensitivity: Double = 1, deadZone: Double = 0.03, smoothing: Double = 0.45) {
        self.pixelsPerRadian = pixelsPerRadian; self.sensitivity = sensitivity
        self.deadZone = deadZone; self.smoothing = smoothing
    }

    /// - Parameters:
    ///   - rotationRate: device-frame angular velocity in rad/s (CMDeviceMotion.rotationRate).
    ///   - gravity: device-frame gravity (CMDeviceMotion.gravity); nil falls back to the device z axis.
    ///   - dt: seconds since the previous sample.
    public mutating func process(rotationRate r: Vector3, gravity: Vector3?, dt: TimeInterval) -> PointerDelta {
        let dt = min(max(dt, 0), 0.1)
        // "Up" in device coordinates is opposite to gravity.
        let up = gravity.flatMap { Vector3(x: -$0.x, y: -$0.y, z: -$0.z).normalized } ?? Vector3(x: 0, y: 0, z: 1)
        let yawRate = r.dot(up)          // positive = turning left (counter-clockwise seen from above)
        let pitchRate = r.x              // positive = top edge tilting up

        let a = min(max(smoothing, 0.01), 1)
        filtered.yaw += a * (applyDeadZone(yawRate) - filtered.yaw)
        filtered.pitch += a * (applyDeadZone(pitchRate) - filtered.pitch)

        let scale = pixelsPerRadian * max(sensitivity, 0.05) * dt
        return carry.take(PointerDelta(dx: -filtered.yaw * scale, dy: -filtered.pitch * scale))
    }

    func applyDeadZone(_ v: Double) -> Double {
        let m = abs(v) - deadZone
        return m > 0 ? (v < 0 ? -m : m) : 0
    }

    /// Call when the clutch is engaged so old motion doesn't bleed into the new gesture.
    public mutating func reset() {
        filtered = (0, 0)
        carry.reset()
    }
}
