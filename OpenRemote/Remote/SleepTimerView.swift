import SwiftUI
import LGKit

/// Sleep timer choices, pushed from Settings.
struct SleepTimerView: View {
    @Environment(TVSession.self) private var session
    @State private var remaining: Int?
    @State private var busy: Int?
    @State private var unsupported: String?

    private let options = [0, 15, 30, 45, 60, 90, 120]

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.self) { minutes in
                    Button { Task { await set(minutes) } } label: {
                        HStack {
                            Text(minutes == 0 ? "Off" : "\(minutes) minutes")
                                .foregroundStyle(.primary)
                            Spacer()
                            if busy == minutes {
                                ProgressView()
                            } else if isSelected(minutes) {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(isSelected(minutes) ? .isSelected : [])
                }
            } header: {
                header
            } footer: {
                if let unsupported {
                    Label(unsupported, systemImage: "exclamationmark.circle")
                } else if session.sleepTimerSupport == .whileAppIsOpen {
                    Text("iOS pauses apps in the background, so a timer that was missed is cancelled rather than turning the TV off later. Turning on Keep Screen Awake helps.")
                } else {
                    Text("The TV turns itself off when the timer ends.")
                }
            }
        }
        .navigationTitle("Sleep Timer")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.observationKey) { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: remaining == nil ? "moon" : "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(remaining == nil ? Color.secondary : Theme.accent)
                Text(remaining.map { "Turns off in \($0) min" } ?? "No timer set")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            if session.sleepTimerSupport == .whileAppIsOpen {
                // Visible without scrolling at the medium detent; the footer has the details.
                Label("This TV's timer can't be set by apps, so Open Remote turns it off for you. **Keep the app open** until then.", systemImage: "info.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .labelStyle(NoteLabelStyle())
            }
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    private func isSelected(_ minutes: Int) -> Bool {
        minutes == 0 ? remaining == nil : remaining == minutes
    }

    private func refresh() async {
        guard let tv = session.tv else { return }
        remaining = await tv.sleepTimerRemaining()
    }

    private func set(_ minutes: Int) async {
        Haptics.tap()
        busy = minutes
        defer { busy = nil }
        do {
            try await session.run { try await $0.setSleepTimer(minutes: minutes == 0 ? nil : minutes) }
            unsupported = nil
            await refresh()
            Haptics.success()
        } catch LGError.unsupported {
            unsupported = "This TV doesn't let apps set its sleep timer. Use the timer in the TV's own settings (General ▸ Timers) instead."
            Haptics.error()
        } catch {
            session.report(error)
        }
    }
}

private struct NoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(Theme.warning)
            configuration.title
        }
    }
}

#Preview {
    NavigationStack { SleepTimerView() }.environment(TVSession.preview())
}
