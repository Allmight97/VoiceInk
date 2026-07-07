import CoreAudio
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                FillerWordsSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Filler Words", systemImage: "textformat") }
        }
        .frame(width: 500, height: 360)
        .scenePadding()
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var shortcutManager: RecordingShortcutManager
    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(AppDefaults.soundFeedbackEnabled) private var soundFeedback = true
    @AppStorage(AppDefaults.unloadModelAfterIdleMinutes) private var unloadMinutes = 0
    @AppStorage(AppDefaults.debugKeepRecordings) private var debugKeepRecordings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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

            Section("Behavior") {
                Toggle("Sound Feedback", isOn: $soundFeedback)
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
