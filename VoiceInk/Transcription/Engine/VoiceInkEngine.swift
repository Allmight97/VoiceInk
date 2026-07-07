import AppKit
import Foundation
import os

@MainActor
final class VoiceInkEngine: NSObject, ObservableObject, RecorderStateProvider {
    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript = ""
    @Published private(set) var isCurrentModelLoaded = false

    let recorder: Recorder
    let model: FluidAudioModel = TranscriptionModelRegistry.parakeetV2
    weak var recorderUIManager: RecorderPanelPresenting?

    private let fluidAudioModelManager: FluidAudioModelManager
    private let serviceRegistry: TranscriptionServiceRegistry
    private let pipeline: TranscriptionPipeline
    private let recordingsDirectory: URL
    private var recordedFile: URL?
    private var activeRecordingID: UUID?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        recorder: Recorder,
        fluidAudioModelManager: FluidAudioModelManager,
        serviceRegistry: TranscriptionServiceRegistry,
        pipeline: TranscriptionPipeline
    ) {
        self.recorder = recorder
        self.fluidAudioModelManager = fluidAudioModelManager
        self.serviceRegistry = serviceRegistry
        self.pipeline = pipeline

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        super.init()

        createRecordingsDirectoryIfNeeded()
    }

    func toggleRecord() async {
        switch recordingState {
        case .idle:
            await startRecording()
        case .starting, .recording:
            await stopAndTranscribe()
        case .transcribing, .enhancing, .busy:
            await cancelRecording()
        }
    }

    func setPushToTalkRecording(isPressed: Bool) async {
        if isPressed {
            if recordingState == .idle {
                await startRecording()
            }
        } else if recordingState == .starting || recordingState == .recording {
            await stopAndTranscribe()
        }
    }

    func cancelRecording() async {
        shouldCancelRecording = true
        activeRecordingID = nil
        await recorder.stopRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await recorderUIManager?.dismissRecorderPanel()
    }

    func resetRecordingSession() async {
        shouldCancelRecording = false
        activeRecordingID = nil
        partialTranscript = ""
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
    }

    private func startRecording() async {
        guard await PermissionAlert.ensureMicrophoneAccess(),
              PermissionAlert.ensureAccessibilityAccess() else {
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        shouldCancelRecording = false
        partialTranscript = ""
        let recordingID = UUID()
        activeRecordingID = recordingID

        let fileURL = recordingsDirectory.appendingPathComponent("\(recordingID.uuidString).wav")
        recordedFile = fileURL
        recordingState = .starting

        do {
            try await recorder.startRecording(toOutputFile: fileURL)
            guard activeRecordingID == recordingID, !shouldCancelRecording else {
                await recorder.stopRecording()
                recordingState = .idle
                return
            }
            recordingState = .recording

            Task { @MainActor [weak self] in
                await self?.warmCurrentModelIfPossible()
            }
        } catch {
            logger.error("Recording failed to start: \(error, privacy: .public)")
            recordingState = .idle
            recordedFile = nil
            NotificationManager.shared.showNotification(
                title: String(localized: "Recording failed to start"),
                type: .error
            )
            await recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func stopAndTranscribe() async {
        let recordingID = activeRecordingID
        activeRecordingID = nil
        partialTranscript = ""
        recordingState = .transcribing
        await recorder.stopRecording()

        guard let audioURL = recordedFile, recordingID != nil, !shouldCancelRecording else {
            recordedFile = nil
            recordingState = .idle
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        do {
            try await pipeline.run(
                audioURL: audioURL,
                model: model,
                shouldCancel: { [weak self] in self?.shouldCancelRecording ?? true },
                onDismiss: { [weak self] in
                    await self?.recorderUIManager?.dismissRecorderPanel()
                }
            )
            isCurrentModelLoaded = serviceRegistry.fluidAudioTranscriptionService.isModelLoaded
        } catch {
            logger.error("Transcription failed: \(error, privacy: .public)")
            StartStopSound.playStop()
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Transcription failed: %@"), error.localizedDescription),
                type: .error
            )
            await recorderUIManager?.dismissRecorderPanel()
        }

        recordedFile = nil
        shouldCancelRecording = false
        if recordingState == .transcribing {
            recordingState = .idle
        }
    }

    private func warmCurrentModelIfPossible() async {
        guard fluidAudioModelManager.isFluidAudioModelDownloaded(model) else { return }

        do {
            try await serviceRegistry.fluidAudioTranscriptionService.loadModel(for: model)
            isCurrentModelLoaded = serviceRegistry.fluidAudioTranscriptionService.isModelLoaded
        } catch {
            logger.error("Model load failed: \(error, privacy: .public)")
        }
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Could not create recordings directory: \(error, privacy: .public)")
        }
    }
}
