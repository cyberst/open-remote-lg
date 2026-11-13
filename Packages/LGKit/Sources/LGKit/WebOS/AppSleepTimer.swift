import Foundation

/// App-side sleep timer. No SSAP call reachable with our manifest sets the TV's own sleep timer (verified on
/// webOS 4.5: `settings/getSystemSettings` refuses the `time.sleepTimer` key, the `timer` service exposes no
/// sleep methods), so the app turns the TV off itself when the time is up.
///
/// Honest limits: it only fires while the app process is running (iOS suspends background apps). Checks use the
/// wall clock, so after a suspension it either fires (if the deadline is just past) or, if the deadline was
/// missed by more than `missGrace`, cancels itself rather than switching the TV off unexpectedly later.
final class AppSleepTimer: @unchecked Sendable {
    /// Deadlines outlive the client: the app replaces its TV client after every trip to the background, and the
    /// new client's timer for the same TV picks the deadline up again (see `resume`).
    private static let storeLock = NSLock()
    nonisolated(unsafe) private static var store: [String: Date] = [:]
    static func clearStore() { storeLock.withLock { store = [:] } }

    private let key: String?
    private let lock = NSLock()
    private var deadline: Date?
    private var warned = false
    private var task: Task<Void, Never>?
    private let checkInterval: TimeInterval
    private let missGrace: TimeInterval
    private let warnBefore: TimeInterval
    private let now: @Sendable () -> Date
    private let warn: @Sendable () async -> Void
    private let fire: @Sendable () async -> Void

    init(key: String? = nil, checkInterval: TimeInterval = 5, missGrace: TimeInterval = 120, warnBefore: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() },
         warn: @escaping @Sendable () async -> Void, fire: @escaping @Sendable () async -> Void) {
        self.key = key
        self.checkInterval = checkInterval; self.missGrace = missGrace; self.warnBefore = warnBefore
        self.now = now; self.warn = warn; self.fire = fire
    }

    deinit { task?.cancel() }

    func set(minutes: Int?) {
        let d: Date? = minutes.flatMap { $0 > 0 ? now().addingTimeInterval(TimeInterval($0) * 60) : nil }
        start(deadline: d, resumed: false)
    }

    /// Re-arms a deadline set through an earlier client for the same TV, if there is one.
    func resume() {
        guard let key, let d = Self.storeLock.withLock({ Self.store[key] }) else { return }
        start(deadline: d, resumed: true)
    }

    /// Stops checking without forgetting the deadline (the client is going away; a new one resumes it).
    func suspend() {
        let t = lock.withLock { () -> Task<Void, Never>? in let t = task; task = nil; return t }
        t?.cancel()
    }

    private func persist(_ d: Date?) {
        guard let key else { return }
        Self.storeLock.withLock { Self.store[key] = d }
    }

    private func start(deadline newDeadline: Date?, resumed: Bool) {
        let old = lock.withLock { () -> Task<Void, Never>? in
            let t = task; task = nil
            deadline = newDeadline
            // A resumed timer already inside the warning window was warned by the previous client.
            warned = resumed && (newDeadline.map { $0.timeIntervalSince(now()) <= warnBefore } ?? false)
            return t
        }
        old?.cancel()
        persist(newDeadline)
        guard newDeadline != nil else { return }
        let t = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.tick() { return }
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
        lock.withLock { task = t }
    }

    var remainingMinutes: Int? {
        lock.withLock {
            guard let d = deadline else { return nil }
            let left = d.timeIntervalSince(now())
            return left > 0 ? Int((left / 60).rounded(.up)) : 0
        }
    }

    /// Returns true when the timer is finished (fired or cancelled).
    private func tick() async -> Bool {
        enum Action: Equatable { case none, warn, fire, done }
        let action: Action = lock.withLock {
            guard let d = deadline else { return .done }
            let left = d.timeIntervalSince(now())
            if left <= -missGrace { deadline = nil; return .done }
            if left <= 0 { deadline = nil; return .fire }
            if left <= warnBefore, !warned { warned = true; return .warn }
            return .none
        }
        if action == .fire || action == .done { persist(nil) }
        switch action {
        case .none: return false
        case .warn: await warn(); return false
        case .fire: await fire(); return true
        case .done: return true
        }
    }
}
