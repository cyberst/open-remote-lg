import SwiftUI

/// The main screen's tabs.
enum RemoteMode: String, CaseIterable, Identifiable {
    case remote, apps, inputs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .remote: "Remote"
        case .apps: "Apps"
        case .inputs: "Inputs"
        }
    }

    var symbol: String {
        switch self {
        case .remote: "av.remote"
        case .apps: "square.grid.2x2"
        case .inputs: "cable.connector.horizontal"
        }
    }
}

/// Sheets presented from the main screen.
enum MainSheet: String, Identifiable {
    case keyboard, voice, cast, inputs, settings, addTV, remotePicker
    var id: String { rawValue }
}
