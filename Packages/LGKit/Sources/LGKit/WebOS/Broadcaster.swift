import Foundation

/// Fans one value source out to any number of `AsyncStream` consumers. Each `stream()` gets its own stream
/// and immediately receives the latest value (if one is known).
final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    init(_ initial: Value? = nil) { current = initial }

    var value: Value? { lock.withLock { current } }
    var subscriberCount: Int { lock.withLock { continuations.count } }

    func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { c in
            let id = UUID()
            let now = lock.withLock { () -> Value? in continuations[id] = c; return current }
            if let now { c.yield(now) }
            c.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ value: Value) {
        let targets = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            current = value
            return Array(continuations.values)
        }
        targets.forEach { $0.yield(value) }
    }

    func finishAll() {
        let targets = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        targets.forEach { $0.finish() }
    }
}

extension Broadcaster where Value: Equatable {
    /// Sends only if the value changed (avoids UI churn on duplicate subscription events).
    func sendIfChanged(_ value: Value) {
        let targets = lock.withLock { () -> [AsyncStream<Value>.Continuation]? in
            if current == value { return nil }
            current = value
            return Array(continuations.values)
        }
        targets?.forEach { $0.yield(value) }
    }
}
