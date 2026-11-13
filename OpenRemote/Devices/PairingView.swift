import SwiftUI
import LGKit

/// Shown while the TV asks the user to approve the app (Accept prompt or PIN).
struct PairingView: View {
    let request: PairingRequest
    let cancel: () -> Void
    @Environment(TVSession.self) private var session
    @State private var pin = ""
    @State private var submitting = false
    @FocusState private var pinFocused: Bool

    private var tvName: String { session.current?.name ?? "your TV" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    TVIllustration(request: request)
                        .padding(.top, 12)
                    VStack(spacing: 10) {
                        Text(request == .acceptOnTV ? "Accept on Your TV" : "Enter the PIN")
                            .font(.title2.weight(.bold))
                        Group {
                            if request == .acceptOnTV {
                                Text("A prompt has appeared on **\(tvName)**. Select **Accept** with the TV's own remote. You only need to do this once.")
                            } else {
                                Text("Type the PIN shown on **\(tvName)**. You only need to do this once.")
                            }
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    if request == .enterPIN { pinEntry } else { waiting }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        .presentationDetents([.large])
        .onChange(of: request, initial: true) { _, r in if r == .enterPIN { pinFocused = true } }
    }

    private var waiting: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                ProgressView()
                Text("Waiting for your TV…").font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Use a PIN Instead") { Haptics.tap(); session.pairWithPIN() }
                .font(.subheadline.weight(.semibold))
                .accessibilityHint("Shows a PIN on the TV to type here instead of accepting a prompt")
        }
        .padding(.top, 4)
    }

    private var pinEntry: some View {
        VStack(spacing: 16) {
            TextField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($pinFocused)
                .frame(height: 64)
                .surface(cornerRadius: 16)
                .accessibilityLabel("PIN shown on the TV")
                .onChange(of: pin) { _, new in pin = String(new.filter(\.isNumber).prefix(8)) }
            Button {
                Task {
                    submitting = true
                    await session.submitPairingPIN(pin)
                    submitting = false
                }
            } label: {
                Group {
                    if submitting { ProgressView().tint(.white) } else { Text("Pair") }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(pin.count < 4 || submitting)
        }
    }
}

/// A stylised TV showing the prompt, with a remote pointing at it. Drawn with shapes + SF Symbols (no image assets).
private struct TVIllustration: View {
    let request: PairingRequest
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.gray.opacity(0.45), lineWidth: 4))
                    .frame(width: 250, height: 150)
                    .overlay { screen }
                Capsule().fill(Color.gray.opacity(0.45)).frame(width: 70, height: 6).padding(.top, 6)
            }
            if request == .acceptOnTV {
                Image(systemName: "av.remote.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(-28))
                    .offset(x: 34, y: 18)
            }
        }
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }

    @ViewBuilder private var screen: some View {
        VStack(spacing: 9) {
            Text(request == .acceptOnTV ? "Allow Open Remote?" : "PIN")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if request == .acceptOnTV {
                HStack(spacing: 8) {
                    Text("Accept")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent))
                        .scaleEffect(pulse ? 1.08 : 1)
                        .shadow(color: Theme.accent.opacity(pulse ? 0.8 : 0.2), radius: 8)
                    Text("Deny")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
            } else {
                Text("• • • • • •")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(pulse ? 1 : 0.55)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
    }
}

#Preview("Accept") {
    PairingView(request: .acceptOnTV) {}.environment(TVSession.preview())
}

#Preview("PIN") {
    PairingView(request: .enterPIN) {}.environment(TVSession.preview())
}
