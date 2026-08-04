import Foundation

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
    static let panelPosition = "RecorderPanelPosition"
}

enum RecorderPanelPosition: String, CaseIterable, Identifiable {
    case bottomCenter = "bottom-center"
    case topCenter = "top-center"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottomCenter: return String(localized: "Bottom Center")
        case .topCenter: return String(localized: "Top Center")
        }
    }

    static var current: RecorderPanelPosition {
        RecorderPanelPosition(
            rawValue: UserDefaults.standard.string(forKey: RecorderDisplaySettingsKeys.panelPosition) ?? ""
        ) ?? .bottomCenter
    }
}

enum AppDefaults {
    static let soundFeedbackEnabled = "IsSoundFeedbackEnabled"
    static let wordReplacementEnabled = "IsWordReplacementEnabled"
    static let wordReplacements = "WordReplacements"
    static let unloadModelAfterIdleMinutes = "UnloadModelAfterIdleMinutes"
    static let debugKeepRecordings = "DebugKeepRecordings"
    static let enableHistoryLog = "EnableHistoryLog"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "restoreClipboardAfterPaste": false,
            "clipboardRestoreDelay": 2.0,
            RecorderDisplaySettingsKeys.showLiveTranscript: false,
            RecorderDisplaySettingsKeys.panelPosition: RecorderPanelPosition.bottomCenter.rawValue,
            enableHistoryLog: true,
            soundFeedbackEnabled: true,
            wordReplacementEnabled: false,
            wordReplacements: [:],
            unloadModelAfterIdleMinutes: 0,
            debugKeepRecordings: false,
            "primaryRecordingShortcutMode": RecordingShortcutManager.Mode.toggle.rawValue
        ])

    }
}
