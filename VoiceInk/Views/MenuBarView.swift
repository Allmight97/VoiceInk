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

        Button(engine.recordingState == .recording ? "Stop Dictation" : "Start Dictation") {
            Task { @MainActor in
                await recorderUIManager.toggleRecorderPanel()
            }
        }
        .disabled(engine.recordingState == .starting || engine.recordingState == .transcribing)

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

    private var statusText: String {
        switch engine.recordingState {
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
}
