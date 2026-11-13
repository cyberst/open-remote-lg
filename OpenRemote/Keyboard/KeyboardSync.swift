import Foundation
import LGKit

/// Mirrors the phone's text field into the TV's focused text field, live.
///
/// Edits are debounced lightly, diffed against what the TV is believed to contain (`TextMirror`),
/// and sent strictly in order by a single sender task. TV-side changes (`observeKeyboard()`) flow back
/// into the phone field when the user isn't mid-typing.
@MainActor
@Observable
final class KeyboardSync {
    var text = ""
    private(set) var tvFieldActive = false

    @ObservationIgnored weak var session: TVSession?
    @ObservationIgnored private var mirror = TextMirror()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var outbox: [Outgoing] = []
    @ObservationIgnored private var pump: Task<Void, Never>?

    private enum Outgoing { case edit(TextEditOp), enter }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Called for every committed change of `text` by the user.
    func userEdited() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Sends whatever hasn't been sent yet, right now.
    func flush() {
        debounce?.cancel(); debounce = nil
        let ops = mirror.localChanged(to: text, now: Self.now)
        enqueue(ops.map(Outgoing.edit))
    }

    func sendEnter() {
        flush()
        enqueue([.enter])
    }

    /// Follows the TV's keyboard state until cancelled. Run from `.task(id:)` keyed on the connected TV.
    func observe(_ tv: any TVControlling) async {
        for await state in tv.observeKeyboard() {
            tvFieldActive = state.visible
            if let adopt = mirror.tvReported(state, localText: text, now: Self.now) {
                text = adopt
            }
        }
    }

    private func enqueue(_ items: [Outgoing]) {
        guard !items.isEmpty else { return }
        outbox.append(contentsOf: items)
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.drain()
            self?.pump = nil
        }
    }

    private func drain() async {
        while !outbox.isEmpty {
            let item = outbox.removeFirst()
            guard let tv = session?.tv else {
                outbox.removeAll()
                session?.lastError = LGError.notConnected.localizedDescription
                return
            }
            do {
                switch item {
                case .edit(.insert(let s)): try await tv.insertText(s, replace: false)
                case .edit(.replace(let s)): try await tv.insertText(s, replace: true)
                case .edit(.delete(let n)): try await tv.deleteCharacters(n)
                case .enter: try await tv.sendEnter()
                }
            } catch {
                session?.lastError = error.localizedDescription
                // Later edits were relative to text the TV may not have; resync with a full rewrite next time.
                outbox.removeAll { if case .edit = $0 { true } else { false } }
                mirror.markOutOfSync()
            }
        }
    }
}
