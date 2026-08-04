import SwiftUI

struct MenuBarView: View {
    let appleSpeechAssetManager: AppleSpeechAssetManager

    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var engine: VoiceInkEngine
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var modelManager: FluidAudioModelManager
    @AppStorage(AppDefaults.transcriptionBackend) private var backendRaw = TranscriptionBackendID.parakeetV2.rawValue
    @AppStorage(AppDefaults.appleSpeechLocale) private var appleSpeechLocaleID = ""
    @State private var appleSpeechState: AppleSpeechAssetState?

    init(appleSpeechAssetManager: AppleSpeechAssetManager = AppleSpeechAssetManager()) {
        self.appleSpeechAssetManager = appleSpeechAssetManager
    }

    private var model: FluidAudioModel {
        TranscriptionModelRegistry.parakeetV2
    }

    var body: some View {
        Group {
            Text(statusText)
            Text("\(selectedBackend.displayName): \(selectedBackendStatus)")

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
        .task(id: "\(backendRaw)|\(appleSpeechLocaleID)") {
            await refreshSelectedBackendStatus()
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

    private var selectedBackend: TranscriptionBackendID {
        TranscriptionBackendID(rawValue: backendRaw) ?? .parakeetV2
    }

    private var selectedLocale: Locale? {
        guard !appleSpeechLocaleID.isEmpty else { return nil }
        return Locale(identifier: appleSpeechLocaleID)
    }

    private var selectedBackendStatus: String {
        switch selectedBackend {
        case .parakeetV2:
            return modelStatus
        case .appleSpeech:
            guard selectedLocale != nil else {
                return String(localized: "Language not selected")
            }

            switch AppleSpeechAssetPresentation.forState(appleSpeechState).status {
            case .checking:
                return String(localized: "Checking")
            case .downloadRequired:
                return String(localized: "Download required")
            case .downloading:
                return String(localized: "Downloading")
            case .ready:
                return String(localized: "Ready")
            case .unsupported:
                return String(localized: "Unsupported")
            case .reservationLimit:
                return String(localized: "Reservation limit")
            case .failed:
                return String(localized: "Failed")
            }
        }
    }

    private var modelStatus: String {
        if modelManager.isFluidAudioModelDownloading(model) {
            return String(localized: "Downloading")
        }
        guard modelManager.isFluidAudioModelDownloaded(model) else {
            return String(localized: "Not Downloaded")
        }
        return engine.isCurrentModelLoaded
            ? String(localized: "Loaded")
            : String(localized: "Ready")
    }

    private func refreshSelectedBackendStatus() async {
        guard selectedBackend == .appleSpeech, let locale = selectedLocale else {
            appleSpeechState = nil
            return
        }

        let backendRawAtStart = backendRaw
        let localeIDAtStart = appleSpeechLocaleID
        let state = await appleSpeechAssetManager.refresh(for: locale)
        guard backendRaw == backendRawAtStart, appleSpeechLocaleID == localeIDAtStart else { return }
        appleSpeechState = state
    }
}
