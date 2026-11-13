import SwiftUI
import LGKit

/// Type on the TV: the text field is mirrored live into whichever text field is selected on the TV;
/// Return presses Enter on the TV.
/// Contract: `KeyboardView()` takes no arguments and reads `@Environment(TVSession.self)`. Presented as a sheet.
struct KeyboardView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var sync = KeyboardSync()
    @State private var focused = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                field
                if let note {
                    Label(note, systemImage: session.isConnected ? "character.cursor.ibeam" : "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 4)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.top, 8)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: note)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        sync.flush()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            sync.session = session
            focused = true
        }
        .onDisappear { sync.flush() }
        .task(id: session.observationKey) {
            guard let tv = session.tv else { return }
            await sync.observe(tv)
        }
    }

    /// Shown only when typing can't land anywhere yet.
    private var note: String? {
        if !session.isConnected { return String(localized: "Not connected to a TV") }
        if sync.tvFieldActive || session.current?.isDemo == true { return nil }
        return String(localized: "Select a text box on the TV to type into it")
    }

    private var field: some View {
        IMETextField(text: $sync.text, isFocused: $focused, placeholder: String(localized: "Type here"),
                     onCommittedChange: { _ in sync.userEdited() },
                     onReturn: send)
            .frame(minHeight: 30)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : .clear, lineWidth: 2)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func send() {
        Haptics.press()
        sync.sendEnter()
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        KeyboardView().environment(TVSession.preview())
    }
}
