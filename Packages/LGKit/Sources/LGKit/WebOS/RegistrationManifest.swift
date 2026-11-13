import Foundation

/// The SSAP registration payload sent on every connect.
///
/// This permission manifest is the one widely used by open-source webOS remote libraries (see
/// THIRD_PARTY_NOTICES.md). Keeping it byte-for-byte compatible means client keys issued for it remain valid
/// across app versions: a TV binds a client key to the permission set it was granted for.
enum RegistrationManifest {
    static let permissions: [String] = [
        "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT",
        "CONTROL_INPUT_TV", "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN",
        "LAUNCH", "LAUNCH_WEBAPP", "READ_APP_STATUS", "READ_COUNTRY_INFO",
        "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_INSTALLED_APPS", "READ_LGE_SDX",
        "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE", "READ_NOTIFICATIONS", "READ_POWER_STATE",
        "READ_RUNNING_APPS", "READ_SETTINGS", "READ_TV_CHANNEL_LIST", "READ_TV_CURRENT_TIME",
        "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED",
        "TEST_SECURE", "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST",
        "WRITE_SETTINGS",
    ]

    /// Builds the `register` payload. `pin == true` asks the TV to show a PIN instead of an Accept prompt
    /// (webOS 3.5+; older TVs ignore it and prompt).
    static func payload(clientKey: String?, pin: Bool) -> JSON {
        var p: [String: JSON] = [
            "forcePairing": false,
            "pairingType": .string(pin ? "PIN" : "PROMPT"),
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.1",
                "permissions": .array(permissions.map { .string($0) }),
            ],
        ]
        if let clientKey, !clientKey.isEmpty { p["client-key"] = .string(clientKey) }
        return .object(p)
    }
}
