import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var modelManager: FluidAudioModelManager

    private var model: FluidAudioModel {
        TranscriptionModelRegistry.parakeetV2
    }

    var body: some View {
        Text(statusText)
        Text("\(model.displayName): \(engine.isCurrentModelLoaded ? "Loaded" : "Unloaded")")

        Divider()

        Button(Self.actionTitle(for: engine.recordingState)) {
            Task { @MainActor in
                await recorderUIManager.toggleRecorderPanel()
            }
        }
        .disabled(Self.isActionDisabled(for: engine.recordingState))

        Button("Copy Last Transcription") {
            if let text = TranscriptionLog.lastText() {
                _ = ClipboardManager.copyToClipboard(text)
            } else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription history yet"),
                    type: .info
                )
            }
        }

        Button("Settings...") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }

    static func statusText(for state: RecordingState) -> String {
        switch state {
        case .idle:
            return "Idle"
        case .starting:
            return "Starting"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .enhancing:
            return "Processing"
        case .busy:
            return "Busy"
        }
    }

    static func actionTitle(for state: RecordingState) -> String {
        state == .recording ? "Stop Dictation" : "Start Dictation"
    }

    static func isActionDisabled(for state: RecordingState) -> Bool {
        state == .starting || state == .transcribing
    }

    private var statusText: String {
        Self.statusText(for: engine.recordingState)
    }
}
