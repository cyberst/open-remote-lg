import Foundation
import LGKit

/// Sends pointer traffic to the TV one message at a time, at most ~60 per second.
/// While a message is in flight, new movement merges into the pending one, so the TV never lags behind
/// the finger; movement stuck for too long (stalled socket) is dropped instead of arriving as a jump.
@MainActor
final class PointerSender {
    weak var session: TVSession?
    private var queue = PointerEventQueue(interval: 1.0 / 60, staleAfter: 0.35)
    private var pump: Task<Void, Never>?
    private var lastErrorReport: TimeInterval = -.infinity

    init(session: TVSession? = nil) { self.session = session }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func move(_ d: PointerDelta, drag: Bool = false) {
        guard !d.isZero else { return }
        enqueue(.move(dx: d.dx, dy: d.dy, drag: drag))
    }

    func scroll(_ d: PointerDelta) {
        guard !d.isZero else { return }
        enqueue(.scroll(dx: d.dx, dy: d.dy))
    }

    func click() { enqueue(.click) }

    /// Releases a drag started with `move(_:drag: true)`.
    func endDrag() { enqueue(.move(dx: 0, dy: 0, drag: false)) }

    /// Drops anything not yet sent (e.g. the view went away).
    func cancelPending() { queue.removeAll() }

    private func enqueue(_ command: PointerCommand) {
        queue.enqueue(command, now: Self.now)
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.drain()
            self?.pump = nil
        }
    }

    private func drain() async {
        while let at = queue.nextSendTime() {
            let wait = at - Self.now
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let command = queue.dequeue(now: Self.now) else { continue }
            guard let tv = session?.tv else { queue.removeAll(); return }
            do {
                switch command {
                case let .move(dx, dy, drag): try await tv.pointerMove(dx: dx, dy: dy, drag: drag)
                case let .scroll(dx, dy): try await tv.pointerScroll(dx: dx, dy: dy)
                case .click: try await tv.pointerClick()
                }
            } catch {
                report(error)
            }
        }
    }

    /// Pointer errors can arrive at 60 Hz; surface at most one every few seconds.
    private func report(_ error: Error) {
        let t = Self.now
        guard t - lastErrorReport > 3 else { return }
        lastErrorReport = t
        session?.lastError = error.localizedDescription
    }
}
