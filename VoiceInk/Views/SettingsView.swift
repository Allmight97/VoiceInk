import CoreAudio
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let appleSpeechAssetManager: AppleSpeechAssetManager

    init(appleSpeechAssetManager: AppleSpeechAssetManager = AppleSpeechAssetManager()) {
        self.appleSpeechAssetManager = appleSpeechAssetManager
    }

    var body: some View {
        TabView {
            GeneralSettingsView(appleSpeechAssetManager: appleSpeechAssetManager)
                .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                FillerWordsSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Filler Words", systemImage: "textformat") }

            Form {
                WordReplacementsSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Replacements", systemImage: "arrow.left.arrow.right") }
        }
        .frame(width: 500, height: 400)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    let appleSpeechAssetManager: AppleSpeechAssetManager

    @EnvironmentObject private var shortcutManager: RecordingShortcutManager
    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(AppDefaults.soundFeedbackEnabled) private var soundFeedback = true
    @AppStorage(AppDefaults.unloadModelAfterIdleMinutes) private var unloadMinutes = 0
    @AppStorage(AppDefaults.debugKeepRecordings) private var debugKeepRecordings = false
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript)
    private var showLiveTranscript = RecorderDisplaySettingsKeys.showLiveTranscriptDefault
    @AppStorage(RecorderDisplaySettingsKeys.panelPosition) private var panelPosition = RecorderPanelPosition.bottomCenter.rawValue
    @AppStorage(AppDefaults.enableHistoryLog) private var historyLog = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    init(appleSpeechAssetManager: AppleSpeechAssetManager) {
        self.appleSpeechAssetManager = appleSpeechAssetManager
    }

    var body: some View {
        Form {
            Section("Dictation") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(action: .primaryRecording) {
                        shortcutManager.updateShortcutStatus()
                    }
                }

                Picker("Shortcut Behavior", selection: $shortcutManager.primaryRecordingShortcutMode) {
                    ForEach(RecordingShortcutManager.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Input Device", selection: selectedDeviceBinding) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            }

            Section("Recorder") {
                Toggle("Show Live Transcript", isOn: $showLiveTranscript)
                Picker("Recorder Position", selection: $panelPosition) {
                    ForEach(RecorderPanelPosition.allCases) { position in
                        Text(position.displayName).tag(position.rawValue)
                    }
                }
            }

            TranscriptionBackendSettingsSection(
                appleSpeechAssetManager: appleSpeechAssetManager
            )

            Section("Behavior") {
                Toggle("Sound Feedback", isOn: $soundFeedback)
                Toggle("Keep History Log", isOn: $historyLog)
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Stepper(value: $unloadMinutes, in: 0...240) {
                    Text("Unload Model After Idle: \(unloadMinutes == 0 ? "Never" : "\(unloadMinutes) min")")
                }
                // LEAN-TODO: model idle unload is a later wave; this pass only preserves the setting.
                Toggle("Keep Debug Recordings", isOn: $debugKeepRecordings)
            }
        }
        .formStyle(.grouped)
    }

    private var selectedDeviceBinding: Binding<AudioDeviceID> {
        Binding(
            get: {
                audioDeviceManager.inputMode == .systemDefault ? 0 : audioDeviceManager.getCurrentDevice()
            },
            set: { newValue in
                if newValue == 0 {
                    audioDeviceManager.selectInputMode(.systemDefault)
                } else {
                    audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: newValue)
                }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    NotificationManager.shared.showNotification(
                        title: "Could not update launch at login",
                        type: .error
                    )
                }
            }
        )
    }
}
