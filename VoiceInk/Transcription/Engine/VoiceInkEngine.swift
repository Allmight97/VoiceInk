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
    private var sampleBuffer: RecordingSampleBuffer?
    private var idleUnloadWorkItem: DispatchWorkItem?
    private var recordInterval: OSSignpostIntervalState?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    private var keepRecordings: Bool {
        UserDefaults.standard.bool(forKey: "DebugKeepRecordings")
    }

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
        endRecordIntervalIfNeeded()
        sampleBuffer?.discard()
        sampleBuffer = nil
        removeRecordingUnlessKept(recordedFile)
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
        endRecordIntervalIfNeeded()
        sampleBuffer?.discard()
        sampleBuffer = nil
        removeRecordingUnlessKept(recordedFile)
        recordedFile = nil
        recordingState = .idle
    }

    private func endRecordIntervalIfNeeded() {
        if let recordInterval {
            LeanSignpost.signposter.endInterval("record", recordInterval)
            self.recordInterval = nil
        }
    }

    private func startRecording() async {
        guard await PermissionAlert.ensureMicrophoneAccess(),
              PermissionAlert.ensureAccessibilityAccess() else {
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        shouldCancelRecording = false
        partialTranscript = ""
        idleUnloadWorkItem?.cancel()
        idleUnloadWorkItem = nil
        let recordingID = UUID()
        activeRecordingID = recordingID

        let fileURL = recordingsDirectory.appendingPathComponent("\(recordingID.uuidString).wav")
        recordedFile = fileURL
        recordingState = .starting

        let buffer = RecordingSampleBuffer()
        sampleBuffer = buffer
        recorder.onAudioChunk = { chunk in
            buffer.append(chunk)
        }

        do {
            try await recorder.startRecording(toOutputFile: fileURL)
            guard activeRecordingID == recordingID, !shouldCancelRecording else {
                await recorder.stopRecording()
                recordingState = .idle
                return
            }
            recordingState = .recording
            recordInterval = LeanSignpost.signposter.beginInterval("record")

            Task(priority: .userInitiated) { @MainActor [weak self] in
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
        if let recordInterval {
            LeanSignpost.signposter.endInterval("record", recordInterval)
            self.recordInterval = nil
        }

        let buffer = sampleBuffer
        sampleBuffer = nil
        let audioURL = recordedFile
        recordedFile = nil
        defer { removeRecordingUnlessKept(audioURL) }

        guard recordingID != nil, !shouldCancelRecording else {
            buffer?.discard()
            recordingState = .idle
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        if buffer?.overflowed == true {
            NotificationManager.shared.showNotification(
                title: String(localized: "Recording exceeded 30 minutes; extra audio was dropped"),
                type: .warning
            )
        }

        do {
            var samples = buffer?.takeFloatSamples() ?? []
            if samples.isEmpty, let audioURL {
                logger.warning("In-memory buffer empty; falling back to recorded file")
                samples = try WAVEncoder.readSamples(from: audioURL)
            }

            try await pipeline.run(
                samples: samples,
                model: model,
                shouldCancel: { [weak self] in self?.shouldCancelRecording ?? true },
                onDismiss: { [weak self] in
                    await self?.recorderUIManager?.dismissRecorderPanel()
                }
            )
            isCurrentModelLoaded = serviceRegistry.fluidAudioTranscriptionService.isModelLoaded
            scheduleIdleUnloadIfEnabled()
        } catch {
            logger.error("Transcription failed: \(error, privacy: .public)")
            StartStopSound.playStop()
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Transcription failed: %@"), error.localizedDescription),
                type: .error
            )
            await recorderUIManager?.dismissRecorderPanel()
        }

        shouldCancelRecording = false
        if recordingState == .transcribing {
            recordingState = .idle
        }
    }

    /// Opt-in: release model memory after N idle minutes (0 = keep resident).
    /// Nothing is scheduled at the default, preserving the zero-idle-timers invariant.
    private func scheduleIdleUnloadIfEnabled() {
        idleUnloadWorkItem?.cancel()
        idleUnloadWorkItem = nil

        let minutes = UserDefaults.standard.integer(forKey: "UnloadModelAfterIdleMinutes")
        guard minutes > 0 else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.recordingState == .idle else { return }
                await self.serviceRegistry.cleanup()
                self.isCurrentModelLoaded = false
                self.logger.notice("Unloaded model after \(minutes, privacy: .public) idle minutes")
            }
        }
        idleUnloadWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(minutes * 60),
            execute: workItem
        )
    }

    private func removeRecordingUnlessKept(_ url: URL?) {
        guard let url, !keepRecordings else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
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
