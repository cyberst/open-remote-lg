import CoreMotion
import Foundation
import LGKit

/// Streams gyroscope motion into TV pointer moves while phone pointing is on (the remote tab's pointer switch).
/// Motion updates run only while `isTracking` — callers stop it when the switch is off, the tab is hidden or the
/// app leaves the foreground.
@MainActor
@Observable
final class AirMouseController {
    /// Apple recommends a single motion manager per app.
    private static let manager = CMMotionManager()

    private(set) var isTracking = false
    /// Pixels the pointer moved during the current clutch hold (to tell a quick tap from aiming).
    @ObservationIgnored private(set) var movedThisHold = 0.0

    @ObservationIgnored let sender = PointerSender()
    /// A slightly wider dead zone than the default so a resting hand (tremor) never nudges the pointer.
    @ObservationIgnored private var mapper = MotionToPointer(deadZone: 0.05)
    @ObservationIgnored private var lastTimestamp: TimeInterval?
    /// After an arrow key the TV hides its pointer; keep it hidden until the phone clearly moves again.
    @ObservationIgnored private var heldUntilMotion = false
    @ObservationIgnored private var heldTravel = 0.0
    /// Pointer pixels of deliberate movement needed to bring the pointer back after an arrow key.
    private let wakeTravel = 40.0

    var isAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AirMouseForceAvailable") { return true }
        #endif
        return Self.manager.isDeviceMotionAvailable
    }

    func start(sensitivity: Double) {
        mapper.sensitivity = sensitivity
        guard !isTracking else { return }
        isTracking = true
        movedThisHold = 0
        heldUntilMotion = false
        mapper.reset()
        lastTimestamp = nil
        let m = Self.manager
        guard m.isDeviceMotionAvailable else { return }
        m.deviceMotionUpdateInterval = 1.0 / 100
        m.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let r = motion.rotationRate, g = motion.gravity
            let sample = (rate: Vector3(x: r.x, y: r.y, z: r.z), gravity: Vector3(x: g.x, y: g.y, z: g.z), t: motion.timestamp)
            MainActor.assumeIsolated { self?.handle(sample.rate, sample.gravity, sample.t) }
        }
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        Self.manager.stopDeviceMotionUpdates()
        lastTimestamp = nil
    }

    /// Stops moving the pointer (so the TV keeps it hidden after an arrow key) until the phone moves deliberately.
    func holdUntilMotion() {
        heldUntilMotion = true
        heldTravel = 0
        mapper.reset()
        sender.cancelPending()
    }

    private func handle(_ rate: Vector3, _ gravity: Vector3, _ t: TimeInterval) {
        guard isTracking else { return }
        defer { lastTimestamp = t }
        guard let last = lastTimestamp else { return }
        let d = mapper.process(rotationRate: rate, gravity: gravity, dt: t - last)
        guard !d.isZero else { return }
        if heldUntilMotion {
            // Leaky sum: only a quick, deliberate movement adds up; slow drift fades away.
            heldTravel = heldTravel * 0.97 + d.magnitude
            guard heldTravel >= wakeTravel else { return }
            heldUntilMotion = false
        }
        movedThisHold += d.magnitude
        sender.move(d)
    }
}
