import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case recorderPanelEscape

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape:
            return false
        case .primaryRecording:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        }
    }

    static let storedActions: [Self] = [
        .primaryRecording
    ]
}
