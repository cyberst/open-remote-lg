import SwiftUI

/// The soft, slightly cool backdrop behind the remote (follows light/dark).
struct SoftBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.09, green: 0.09, blue: 0.12), Color(red: 0.03, green: 0.03, blue: 0.05)]
                       : [Color(red: 0.95, green: 0.95, blue: 0.99), Color(red: 0.88, green: 0.89, blue: 0.96)],
                       startPoint: .top, endPoint: .bottom)
    }
}
