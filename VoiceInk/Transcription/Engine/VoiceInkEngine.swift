import AppKit
import Foundation
import os

@MainActor
final class VoiceInkEngine: NSObject, ObservableObject, RecorderStateProvider {
    enum ModelRecordingGate: Equatable {
        case ready
        case downloading
        case missing
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript = ""
    @Published private(set) var isCurrentModelLoaded = false

    let recorder: Recorder
    let model: FluidAudioModel = TranscriptionModelRegistry.parakeetV2
    weak var recorderUIManager: RecorderPanelPresenting?

    private let fluidAudioModelManager: FluidAudioModelManager
    private let fluidAudioService: FluidAudioTranscriptionService
    private let pipeline: TranscriptionPipeline
    private let recordingsDirectory: URL
    private var recordedFile: URL?
    private var activeRecordingID: UUID?
    private var activeOperationID: UUID?
    private var sampleBuffer: RecordingSampleBuffer?
    private var partialTranscriptTask: Task<Void, Never>?
    private var idleUnloadWorkItem: DispatchWorkItem?
    private var recordInterval: OSSignpostIntervalState?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    private var keepRecordings: Bool {
        UserDefaults.standard.bool(forKey: "DebugKeepRecordings")
    }

    init(
        recorder: Recorder,
        fluidAudioModelManager: FluidAudioModelManager,
        fluidAudioService: FluidAudioTranscriptionService,
        pipeline: TranscriptionPipeline
    ) {
        self.recorder = recorder
        self.fluidAudioModelManager = fluidAudioModelManager
        self.fluidAudioService = fluidAudioService
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
        activeOperationID = nil
        await recorder.stopRecording()
        await finishPartialTranscription()
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
        activeOperationID = nil
        partialTranscript = ""
        await recorder.stopRecording()
        await finishPartialTranscription()
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
        switch Self.modelRecordingGate(
            isDownloading: fluidAudioModelManager.isFluidAudioModelDownloading(model),
            isDownloaded: fluidAudioModelManager.isFluidAudioModelDownloaded(model)
        ) {
        case .downloading:
            NotificationManager.shared.showNotification(
                title: String(localized: "Wait for the Parakeet v2 download to finish"),
                type: .warning
            )
            await recorderUIManager?.dismissRecorderPanel()
            return
        case .missing:
            NotificationManager.shared.showNotification(
                title: String(localized: "Download Parakeet v2 in Settings to start recording"),
                type: .warning
            )
            await recorderUIManager?.dismissRecorderPanel()
            return
        case .ready:
            break
        }

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
        activeOperationID = recordingID

        let fileURL = recordingsDirectory.appendingPathComponent("\(recordingID.uuidString).wav")
        recordedFile = fileURL
        recordingState = .starting

        let buffer = RecordingSampleBuffer()
        sampleBuffer = buffer
        recorder.onAudioChunk = { @Sendable chunk in
            buffer.append(chunk)
        }

        do {
            try await recorder.startRecording(toOutputFile: fileURL)
            guard isOperationCurrent(recordingID), activeRecordingID == recordingID else {
                await recorder.stopRecording()
                if isOperationCurrent(recordingID) {
                    recordingState = .idle
                }
                return
            }
            recordingState = .recording
            recordInterval = LeanSignpost.signposter.beginInterval("record")

            Task(priority: .userInitiated) { @MainActor [weak self] in
                await self?.warmCurrentModelIfPossible()
            }
            startPartialTranscriptionIfEnabled(buffer: buffer, recordingID: recordingID)
        } catch {
            guard isOperationCurrent(recordingID) else { return }
            logger.error("Recording failed to start: \(error, privacy: .public)")
            recordingState = .idle
            recordedFile = nil
            activeRecordingID = nil
            activeOperationID = nil
            NotificationManager.shared.showNotification(
                title: String(localized: "Recording failed to start"),
                type: .error
            )
            await recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func stopAndTranscribe() async {
        let recordingID = activeRecordingID
        let operationID = activeOperationID
        activeRecordingID = nil
        partialTranscript = ""
        recordingState = .transcribing
        await recorder.stopRecording()
        await finishPartialTranscription()
        if let recordInterval {
            LeanSignpost.signposter.endInterval("record", recordInterval)
            self.recordInterval = nil
        }

        let buffer = sampleBuffer
        sampleBuffer = nil
        let audioURL = recordedFile
        recordedFile = nil
        defer { removeRecordingUnlessKept(audioURL) }

        guard recordingID != nil, let operationID, isOperationCurrent(operationID) else {
            buffer?.discard()
            if let operationID, isOperationCurrent(operationID) {
                recordingState = .idle
                await recorderUIManager?.dismissRecorderPanel()
            }
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
                isOperationCurrent: { [weak self] in
                    self?.isOperationCurrent(operationID) ?? false
                },
                onDismiss: { [weak self] in
                    guard let self, self.isOperationCurrent(operationID) else { return }
                    await self.recorderUIManager?.dismissRecorderPanel()
                }
            )
            guard isOperationCurrent(operationID) else { return }
            isCurrentModelLoaded = await fluidAudioService.isModelLoaded
            scheduleIdleUnloadIfEnabled()
        } catch {
            guard isOperationCurrent(operationID) else { return }
            logger.error("Transcription failed: \(error, privacy: .public)")
            StartStopSound.playStop()
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Transcription failed: %@"), error.localizedDescription),
                type: .error
            )
            await recorderUIManager?.dismissRecorderPanel()
        }

        guard isOperationCurrent(operationID) else { return }
        shouldCancelRecording = false
        activeOperationID = nil
        if recordingState == .transcribing {
            recordingState = .idle
        }
    }

    private func isOperationCurrent(_ operationID: UUID) -> Bool {
        TranscriptionPipeline.isOperationCurrent(
            operationID: operationID,
            activeOperationID: activeOperationID,
            isCancelled: shouldCancelRecording
        )
    }

    static func modelRecordingGate(isDownloading: Bool, isDownloaded: Bool) -> ModelRecordingGate {
        if isDownloading { return .downloading }
        return isDownloaded ? .ready : .missing
    }

    /// Opt-in live transcript: while recording, periodically transcribe a
    /// snapshot of the in-memory buffer and publish it as partialTranscript.
    /// Inert unless ShowLiveTranscript is on; costs CPU only while recording.
    private func startPartialTranscriptionIfEnabled(buffer: RecordingSampleBuffer, recordingID: UUID) {
        guard UserDefaults.standard.bool(forKey: "ShowLiveTranscript") else { return }

        partialTranscriptTask = Task(priority: .utility) { @MainActor [weak self] in
            // One second of audio minimum before the first partial pass.
            let minimumSamples = 16_000
            while let self, !Task.isCancelled,
                  self.recordingState == .recording,
                  self.activeRecordingID == recordingID {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled,
                      self.recordingState == .recording,
                      self.activeRecordingID == recordingID else { break }

                let samples = buffer.snapshotFloatSamples()
                guard samples.count >= minimumSamples else { continue }

                guard let text = try? await self.fluidAudioService.transcribe(samples: samples) else { continue }

                if !Task.isCancelled,
                   self.recordingState == .recording,
                   self.activeRecordingID == recordingID {
                    self.partialTranscript = text
                }
            }
        }
    }

    /// Cancels the partial-transcript loop and waits for any in-flight pass,
    /// so the final transcription never runs concurrently with a partial one.
    private func finishPartialTranscription() async {
        partialTranscriptTask?.cancel()
        await partialTranscriptTask?.value
        partialTranscriptTask = nil
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
                await self.fluidAudioService.cleanup()
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
            try await fluidAudioService.loadModel()
            isCurrentModelLoaded = await fluidAudioService.isModelLoaded
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
