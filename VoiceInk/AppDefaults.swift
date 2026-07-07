import Foundation

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum AppDefaults {
    static let soundFeedbackEnabled = "IsSoundFeedbackEnabled"
    static let wordReplacementEnabled = "IsWordReplacementEnabled"
    static let wordReplacements = "WordReplacements"
    static let unloadModelAfterIdleMinutes = "UnloadModelAfterIdleMinutes"
    static let debugKeepRecordings = "DebugKeepRecordings"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "restoreClipboardAfterPaste": false,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,
            PasteMethod.userDefaultsKey: PasteMethod.standard.rawValue,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": false,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: false,
            "IsMenuBarOnly": true,
            soundFeedbackEnabled: true,
            wordReplacementEnabled: false,
            wordReplacements: [:],
            unloadModelAfterIdleMinutes: 0,
            debugKeepRecordings: false,
            "primaryRecordingShortcut": RecordingShortcutManager.ShortcutSelection.custom.rawValue,
            "primaryRecordingShortcutMode": RecordingShortcutManager.Mode.toggle.rawValue
        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
