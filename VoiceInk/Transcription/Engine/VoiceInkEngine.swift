import AppKit
import Foundation
import os

@MainActor
final class IdleBackendUnloader {
    private var task: Task<Void, Never>?

    func schedule(
        after delay: Duration,
        cleanup: @escaping @MainActor @Sendable () async -> Void
    ) {
        cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await cleanup()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

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

    let recorder: Recorder
    let model: FluidAudioModel = TranscriptionModelRegistry.parakeetV2
    weak var recorderUIManager: RecorderPanelPresenting?

    private let fluidAudioModelManager: FluidAudioModelManager
    private let appleSpeechAssetManager: AppleSpeechAssetManager
    private let backendRouter: TranscriptionBackendRouter
    private let selectionStorage: any TranscriptionSelectionStorage
    private let pipeline: TranscriptionPipeline
    private let recordingsDirectory: URL
    private var recordedFile: URL?
    private var activeRecordingID: UUID?
    private var activeOperationID: UUID?
    private var sampleBuffer: RecordingSampleBuffer?
    private var activeBackend: (any TranscriptionBackend)?
    private var activeBackendConfiguration: TranscriptionConfiguration?
    private var partialTranscriptTask: Task<Void, Never>?
    private let idleBackendUnloader = IdleBackendUnloader()
    private var recordInterval: OSSignpostIntervalState?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    private var keepRecordings: Bool {
        UserDefaults.standard.bool(forKey: "DebugKeepRecordings")
    }

    init(
        recorder: Recorder,
        fluidAudioModelManager: FluidAudioModelManager,
        appleSpeechAssetManager: AppleSpeechAssetManager,
        backendRouter: TranscriptionBackendRouter,
        selectionStorage: any TranscriptionSelectionStorage,
        pipeline: TranscriptionPipeline
    ) {
        self.recorder = recorder
        self.fluidAudioModelManager = fluidAudioModelManager
        self.appleSpeechAssetManager = appleSpeechAssetManager
        self.backendRouter = backendRouter
        self.selectionStorage = selectionStorage
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
        case .transcribing:
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
        let backend = activeBackend
        activeRecordingID = nil
        activeOperationID = nil
        await recorder.stopRecording()
        await finishPartialTranscription()
        endRecordIntervalIfNeeded()
        sampleBuffer?.discard()
        sampleBuffer = nil
        activeBackend = nil
        activeBackendConfiguration = nil
        await backend?.cleanup()
        removeRecordingUnlessKept(recordedFile)
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await recorderUIManager?.dismissRecorderPanel()
    }

    func resetRecordingSession() async {
        shouldCancelRecording = false
        let backend = activeBackend
        activeRecordingID = nil
        activeOperationID = nil
        partialTranscript = ""
        await recorder.stopRecording()
        await finishPartialTranscription()
        endRecordIntervalIfNeeded()
        sampleBuffer?.discard()
        sampleBuffer = nil
        activeBackend = nil
        activeBackendConfiguration = nil
        await backend?.cleanup()
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
        let configuration = selectionStorage.load()
        let backend = backendRouter.backend(for: configuration)

        guard await selectedBackendIsAvailable(configuration) else {
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        guard await PermissionAlert.ensureMicrophoneAccess(),
              PermissionAlert.ensureAccessibilityAccess() else {
            await recorderUIManager?.dismissRecorderPanel()
            return
        }

        shouldCancelRecording = false
        partialTranscript = ""
        idleBackendUnloader.cancel()
        let recordingID = UUID()
        activeRecordingID = recordingID
        activeOperationID = recordingID
        activeBackend = backend
        activeBackendConfiguration = configuration

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
                await self?.warmCurrentBackendIfPossible(
                    backend,
                    configuration: configuration
                )
            }
            startPartialTranscriptionIfEnabled(
                buffer: buffer,
                recordingID: recordingID,
                backend: backend,
                configuration: configuration
            )
        } catch {
            guard isOperationCurrent(recordingID) else { return }
            logger.error("Recording failed to start: \(error, privacy: .public)")
            recordingState = .idle
            recordedFile = nil
            activeRecordingID = nil
            activeOperationID = nil
            activeBackend = nil
            activeBackendConfiguration = nil
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
        let backend = activeBackend
        let backendConfiguration = activeBackendConfiguration
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

        guard recordingID != nil,
              let operationID,
              let backend,
              let backendConfiguration,
              isOperationCurrent(operationID) else {
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
                transcribe: { samples in
                    try await backend.transcribe(
                        samples: samples,
                        configuration: backendConfiguration
                    )
                },
                isOperationCurrent: { [weak self] in
                    self?.isOperationCurrent(operationID) ?? false
                },
                onDismiss: { [weak self] in
                    guard let self, self.isOperationCurrent(operationID) else { return }
                    await self.recorderUIManager?.dismissRecorderPanel()
                }
            )
            guard isOperationCurrent(operationID) else { return }
            scheduleIdleUnloadIfEnabled(backend: backend)
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
        activeBackend = nil
        activeBackendConfiguration = nil
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

    private func selectedBackendIsAvailable(_ configuration: TranscriptionConfiguration) async -> Bool {
        switch configuration.backend {
        case .parakeetV2:
            switch Self.modelRecordingGate(
                isDownloading: fluidAudioModelManager.isFluidAudioModelDownloading(model),
                isDownloaded: fluidAudioModelManager.isFluidAudioModelDownloaded(model)
            ) {
            case .ready:
                return true
            case .downloading:
                showBackendWarning("Wait for the Parakeet v2 download to finish")
            case .missing:
                showBackendWarning("Download Parakeet v2 in Settings to start recording")
            }

        case .appleSpeech:
            guard let locale = configuration.locale else {
                showBackendWarning("Choose an Apple Speech language in Settings")
                return false
            }

            switch await appleSpeechAssetManager.refresh(for: locale) {
            case .ready:
                return true
            case .requested, .downloading:
                showBackendWarning("Wait for the Apple Speech language download to finish")
            case .unsupported:
                showBackendWarning("This Apple Speech language is not supported")
            case .reservationLimit:
                showBackendWarning("Release an unused Apple Speech language reservation in Settings")
            case .absent, .reclaimed:
                showBackendWarning("Download the selected Apple Speech language in Settings")
            case .failed:
                showBackendWarning("Apple Speech is unavailable; check Settings and try again")
            }
        }

        return false
    }

    private func showBackendWarning(_ title: LocalizedStringResource) {
        NotificationManager.shared.showNotification(
            title: String(localized: title),
            type: .warning
        )
    }

    /// Live transcript: while recording, periodically transcribe a
    /// snapshot of the in-memory buffer and publish it as partialTranscript.
    /// Inert unless ShowLiveTranscript is on; costs CPU only while recording.
    private func startPartialTranscriptionIfEnabled(
        buffer: RecordingSampleBuffer,
        recordingID: UUID,
        backend: any TranscriptionBackend,
        configuration: TranscriptionConfiguration
    ) {
        guard UserDefaults.standard.bool(forKey: RecorderDisplaySettingsKeys.showLiveTranscript) else { return }

        partialTranscriptTask = Task(priority: .utility) { @MainActor [weak self] in
            // One second of audio minimum before the first partial pass.
            let minimumSamples = 16_000
            while let self, !Task.isCancelled,
                  Self.shouldContinuePartialTranscription(
                    showLiveTranscript: UserDefaults.standard.bool(
                        forKey: RecorderDisplaySettingsKeys.showLiveTranscript
                    ),
                    recordingState: self.recordingState,
                    activeRecordingID: self.activeRecordingID,
                    recordingID: recordingID
                  ) {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled,
                      Self.shouldContinuePartialTranscription(
                        showLiveTranscript: UserDefaults.standard.bool(
                            forKey: RecorderDisplaySettingsKeys.showLiveTranscript
                        ),
                        recordingState: self.recordingState,
                        activeRecordingID: self.activeRecordingID,
                        recordingID: recordingID
                      ) else { break }

                let samples = buffer.snapshotFloatSamples()
                guard samples.count >= minimumSamples else { continue }

                guard let text = try? await backend.transcribe(
                    samples: samples,
                    configuration: configuration
                ) else { continue }

                if !Task.isCancelled,
                   self.recordingState == .recording,
                   self.activeRecordingID == recordingID {
                    self.partialTranscript = text
                }
            }
        }
    }

    static func shouldContinuePartialTranscription(
        showLiveTranscript: Bool,
        recordingState: RecordingState,
        activeRecordingID: UUID?,
        recordingID: UUID
    ) -> Bool {
        showLiveTranscript &&
            recordingState == .recording &&
            activeRecordingID == recordingID
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
    private func scheduleIdleUnloadIfEnabled(backend: any TranscriptionBackend) {
        idleBackendUnloader.cancel()

        let minutes = UserDefaults.standard.integer(forKey: AppDefaults.unloadModelAfterIdleMinutes)
        guard minutes > 0 else { return }

        idleBackendUnloader.schedule(after: .seconds(minutes * 60)) { [weak self] in
            guard let self, self.recordingState == .idle else { return }
            await backend.cleanup()
            self.logger.notice("Unloaded model after \(minutes, privacy: .public) idle minutes")
        }
    }

    private func removeRecordingUnlessKept(_ url: URL?) {
        guard let url, !keepRecordings else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func warmCurrentBackendIfPossible(
        _ backend: any TranscriptionBackend,
        configuration: TranscriptionConfiguration
    ) async {
        do {
            try await backend.prepare(configuration: configuration)
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
