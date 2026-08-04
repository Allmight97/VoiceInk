import AppKit
import AVFoundation
import SwiftUI

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var recorder: Recorder
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var engine: VoiceInkEngine
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    private let appleSpeechAssetManager: AppleSpeechAssetManager

    init() {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        AppDefaults.registerDefaults()

        let recorder = Recorder()
        let fluidAudioModelManager = FluidAudioModelManager()
        let fluidAudioService = FluidAudioTranscriptionService()
        let appleSpeechAssetManager = AppleSpeechAssetManager()
        let appleSpeechService = AppleSpeechTranscriptionService(assets: appleSpeechAssetManager)
        let backendRouter = TranscriptionBackendRouter(
            parakeetV2: fluidAudioService,
            appleSpeech: appleSpeechService
        )
        let selectionStorage = UserDefaultsTranscriptionSelectionStorage()
        let delivery = TranscriptionDelivery()
        let pipeline = TranscriptionPipeline(delivery: delivery)
        let engine = VoiceInkEngine(
            recorder: recorder,
            fluidAudioModelManager: fluidAudioModelManager,
            appleSpeechAssetManager: appleSpeechAssetManager,
            backendRouter: backendRouter,
            selectionStorage: selectionStorage,
            pipeline: pipeline
        )
        let recorderUIManager = RecorderUIManager()
        recorderUIManager.configure(engine: engine, recorder: recorder)
        engine.recorderUIManager = recorderUIManager

        let recordingShortcutManager = RecordingShortcutManager(
            engine: engine,
            recorderUIManager: recorderUIManager
        )

        _recorder = StateObject(wrappedValue: recorder)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _engine = StateObject(wrappedValue: engine)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)
        self.appleSpeechAssetManager = appleSpeechAssetManager

        Task { @MainActor in
            await recorderUIManager.resetOnLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appleSpeechAssetManager: appleSpeechAssetManager)
                .environmentObject(engine)
                .environmentObject(recorderUIManager)
                .environmentObject(fluidAudioModelManager)
        } label: {
            Image(systemName: engine.recordingState == .recording ? "waveform.circle.fill" : "mic.circle")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(appleSpeechAssetManager: appleSpeechAssetManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(fluidAudioModelManager)
        }
    }
}

@MainActor
enum PermissionAlert {
    static func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            show(
                title: "Microphone Access Required",
                message: "VoiceInk needs microphone access to record dictation.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
            return false
        @unknown default:
            return false
        }
    }

    static func ensureAccessibilityAccess() -> Bool {
        guard AXIsProcessTrusted() else {
            show(
                title: "Accessibility Access Required",
                message: "VoiceInk needs accessibility access to paste transcriptions into the frontmost app.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            return false
        }
        return true
    }

    private static func show(title: String, message: String, settingsURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
