import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case cancelRecorder
    case recorderPanelEscape

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape:
            return false
        case .primaryRecording, .cancelRecorder:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .cancelRecorder:
            return "cancelRecorder"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        }
    }

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let storedActions: [Self] = [
        .primaryRecording,
        .cancelRecorder
    ]
}
