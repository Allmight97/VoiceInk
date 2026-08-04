import Testing
import Foundation
import CoreAudio
import FluidAudio
import SwiftUI
@testable import VoiceInk

@Suite(.serialized)
struct VoiceInkTests {

    @Test("Output filtering removes bracketed transcript artifacts")
    @MainActor
    func outputFilteringRemovesBracketedArtifacts() {
        let filtered = TranscriptionOutputFilter.filter("Keep [aside]   this.")

        #expect(filtered == "Keep this.")
    }

    @Test("Core Audio byte contracts reject malformed property sizes")
    func coreAudioByteContracts() {
        let scalarBytes = MemoryLayout<UInt32>.size
        #expect(CoreAudioByteContract.hasExactSize(UInt32(scalarBytes), expectedBytes: scalarBytes))
        #expect(!CoreAudioByteContract.hasExactSize(UInt32(scalarBytes - 1), expectedBytes: scalarBytes))
        #expect(!CoreAudioByteContract.hasExactSize(UInt32(scalarBytes + 1), expectedBytes: scalarBytes))

        let deviceStride = MemoryLayout<AudioDeviceID>.stride
        #expect(CoreAudioByteContract.elementCount(returnedBytes: 0, elementStride: deviceStride) == 0)
        #expect(CoreAudioByteContract.elementCount(
            returnedBytes: UInt32(deviceStride * 2),
            elementStride: deviceStride
        ) == 2)
        #expect(CoreAudioByteContract.elementCount(
            returnedBytes: UInt32(deviceStride + 1),
            elementStride: deviceStride
        ) == nil)

        let bufferHeaderBytes = MemoryLayout<AudioBufferList>.size
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        #expect(CoreAudioByteContract.variableStructByteCount(
            elementCount: 1,
            minimumHeaderBytes: bufferHeaderBytes,
            elementStride: bufferStride
        ) == bufferHeaderBytes)
        #expect(CoreAudioByteContract.variableStructByteCount(
            elementCount: 3,
            minimumHeaderBytes: bufferHeaderBytes,
            elementStride: bufferStride
        ) == bufferHeaderBytes + bufferStride * 2)
        #expect(CoreAudioByteContract.variableStructByteCount(
            elementCount: 0,
            minimumHeaderBytes: bufferHeaderBytes,
            elementStride: bufferStride
        ) == nil)
    }

    @Test("Menu status and recorder panel presentation derive from engine state")
    @MainActor
    func presentationDerivationsStayStateOwned() {
        let expected: [(RecordingState, String, String, Bool, String, Bool)] = [
            (.idle, "Idle", "Start Dictation", false, "Start recording", false),
            (.starting, "Starting", "Start Dictation", true, "Starting recording", true),
            (.recording, "Recording", "Stop Dictation", false, "Stop recording", false),
            (.transcribing, "Transcribing", "Start Dictation", true, "Transcribing recording", true)
        ]

        for (state, status, actionTitle, actionDisabled, accessibilityLabel, buttonDisabled) in expected {
            #expect(MenuBarView.statusText(for: state) == status)
            #expect(MenuBarView.actionTitle(for: state) == actionTitle)
            #expect(MenuBarView.isActionDisabled(for: state) == actionDisabled)
            #expect(RecorderRecordButton.accessibilityLabel(for: state) == accessibilityLabel)
            #expect(RecorderRecordButton.isDisabled(for: state) == buttonDisabled)
        }

        #expect(MiniRecorderView<TestRecorderState>.shouldShowLiveTranscript(
            showLiveTranscript: true,
            recordingState: .recording,
            partialTranscript: "hello"
        ))
        #expect(!MiniRecorderView<TestRecorderState>.shouldShowLiveTranscript(
            showLiveTranscript: true,
            recordingState: .recording,
            partialTranscript: ""
        ))
        #expect(!MiniRecorderView<TestRecorderState>.shouldShowLiveTranscript(
            showLiveTranscript: true,
            recordingState: .idle,
            partialTranscript: "hello"
        ))
    }

    @Test("Stale notification dismissals cannot close a replacement")
    @MainActor
    func notificationReplacementDismissalUsesCurrentToken() {
        let first = UUID()
        let replacement = UUID()

        #expect(NotificationManager.shouldDismiss(
            notificationID: first,
            currentNotificationID: first
        ))
        #expect(!NotificationManager.shouldDismiss(
            notificationID: first,
            currentNotificationID: replacement
        ))
        #expect(!NotificationManager.shouldDismiss(
            notificationID: replacement,
            currentNotificationID: nil
        ))
    }

    @Test("A cancelled transcription operation cannot affect a newer operation")
    @MainActor
    func staleTranscriptionOperationIsNotCurrent() {
        let cancelledOperation = UUID()
        let replacementOperation = UUID()

        #expect(!TranscriptionPipeline.isOperationCurrent(
            operationID: cancelledOperation,
            activeOperationID: replacementOperation,
            isCancelled: false
        ))
        #expect(!TranscriptionPipeline.isOperationCurrent(
            operationID: cancelledOperation,
            activeOperationID: cancelledOperation,
            isCancelled: true
        ))
        #expect(TranscriptionPipeline.isOperationCurrent(
            operationID: replacementOperation,
            activeOperationID: replacementOperation,
            isCancelled: false
        ))
    }

    @Test("Recorder close dismisses idle state and cancels active state")
    @MainActor
    func recorderCloseOwnsActiveCancellation() async {
        var cancellationCount = 0
        var dismissalCount = 0

        await RecorderUIManager.performCloseAction(
            recordingState: .idle,
            cancel: { cancellationCount += 1 },
            dismiss: { dismissalCount += 1 }
        )
        #expect(cancellationCount == 0)
        #expect(dismissalCount == 1)

        await RecorderUIManager.performCloseAction(
            recordingState: .transcribing,
            cancel: { cancellationCount += 1 },
            dismiss: { dismissalCount += 1 }
        )
        #expect(cancellationCount == 1)
        #expect(dismissalCount == 1)
    }

    @Test("Replacement operation prevents stale dismissal, paste, and logging")
    @MainActor
    func replacementOperationRejectsStaleDelivery() async throws {
        let staleOperation = UUID()
        let replacementOperation = UUID()
        var activeOperation = staleOperation
        var dismissCount = 0
        var pastedTexts: [String] = []
        var loggedTexts: [String] = []
        let delivery = TranscriptionDelivery(
            playStopSound: {},
            paste: { pastedTexts.append($0) }
        )
        let pipeline = TranscriptionPipeline(
            delivery: delivery,
            appendLog: { loggedTexts.append($0) }
        )

        try await pipeline.run(
            samples: [0],
            transcribe: { _ in
                activeOperation = replacementOperation
                return "stale text"
            },
            isOperationCurrent: { activeOperation == staleOperation },
            onDismiss: { dismissCount += 1 }
        )

        #expect(dismissCount == 0)
        #expect(pastedTexts.isEmpty)
        #expect(loggedTexts.isEmpty)
    }

    @Test("A transcription cancelled during panel dismissal is never pasted")
    @MainActor
    func cancellationDuringDismissPreventsPaste() async {
        var isCurrent = true
        var stopSoundCount = 0
        var pastedTexts: [String] = []
        let delivery = TranscriptionDelivery(
            playStopSound: { stopSoundCount += 1 },
            paste: { pastedTexts.append($0) }
        )

        await delivery.deliver(
            text: "stale text",
            actions: TranscriptionDelivery.Actions(
                isOperationCurrent: { isCurrent },
                dismiss: { isCurrent = false }
            )
        )

        #expect(stopSoundCount == 1)
        #expect(pastedTexts.isEmpty)
    }

    @Test("Missing cached models fail before invoking the loader")
    func missingModelFailsWithoutLoading() async {
        let loader = TestModelLoader()
        let service = FluidAudioTranscriptionService(
            modelStore: FluidAudioModelStore(
                modelsExist: { _ in false },
                loadFromCache: { version in
                    try await loader.load(version)
                }
            )
        )

        do {
            _ = try await service.getOrLoadModels(for: .v2)
            #expect(Bool(false), "missing model should throw")
        } catch let error as FluidAudioTranscriptionServiceError {
            #expect(error == .modelNotDownloaded)
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        #expect(await loader.invocationCount == 0)
    }

    @Test("Selection storage migrates missing and invalid backends to Parakeet")
    @MainActor
    func selectionStorageMigratesInvalidBackend() {
        let testDefaults = TestSelectionDefaults()
        defer { testDefaults.cleanup() }
        let storage = UserDefaultsTranscriptionSelectionStorage(defaults: testDefaults.store)

        #expect(storage.load() == TranscriptionConfiguration(backend: .parakeetV2))
        #expect(testDefaults.store.string(forKey: AppDefaults.transcriptionBackend) == TranscriptionBackendID.parakeetV2.rawValue)

        testDefaults.store.set("not-a-backend", forKey: AppDefaults.transcriptionBackend)
        #expect(storage.load() == TranscriptionConfiguration(backend: .parakeetV2))
        #expect(testDefaults.store.string(forKey: AppDefaults.transcriptionBackend) == TranscriptionBackendID.parakeetV2.rawValue)
    }

    @Test("Selection storage persists Apple locale without changing the backend default")
    @MainActor
    func selectionStoragePersistsLocaleInIsolatedDefaults() {
        let testDefaults = TestSelectionDefaults()
        defer { testDefaults.cleanup() }
        let storage = UserDefaultsTranscriptionSelectionStorage(defaults: testDefaults.store)
        let appleConfiguration = TranscriptionConfiguration(
            backend: .appleSpeech,
            localeIdentifier: "en-GB"
        )

        storage.save(appleConfiguration)
        #expect(storage.load() == appleConfiguration)

        storage.save(TranscriptionConfiguration(backend: .parakeetV2))
        #expect(storage.load() == TranscriptionConfiguration(backend: .parakeetV2))
        #expect(testDefaults.store.string(forKey: AppDefaults.appleSpeechLocale) == "en-GB")
    }

    @Test("A recording snapshot is unchanged by later Settings changes")
    @MainActor
    func backendSnapshotIsImmutableAcrossSelectionChanges() {
        let testDefaults = TestSelectionDefaults()
        defer { testDefaults.cleanup() }
        let storage = UserDefaultsTranscriptionSelectionStorage(defaults: testDefaults.store)
        let selected = TranscriptionConfiguration(
            backend: .appleSpeech,
            localeIdentifier: "en-GB"
        )

        storage.save(selected)
        let recordingSnapshot = TranscriptionBackendSnapshot(configuration: storage.load())

        storage.save(TranscriptionConfiguration(
            backend: .appleSpeech,
            localeIdentifier: "fr-FR"
        ))

        #expect(recordingSnapshot.configuration == selected)
        #expect(storage.load().localeIdentifier == "fr-FR")
    }

    @Test("Backend router is closed and never falls back from Apple Speech")
    func backendRouterRoutesOnlyTheSelectedBackend() async throws {
        let parakeet = TestTranscriptionBackend(result: "parakeet")
        let appleSpeech = TestTranscriptionBackend(result: "apple")
        let router = TranscriptionBackendRouter(
            parakeetV2: parakeet,
            appleSpeech: appleSpeech
        )

        let parakeetBackend = try router.backend(for: TranscriptionBackendSnapshot(backend: .parakeetV2))
        #expect(try await parakeetBackend.transcribe(
            samples: [1],
            configuration: TranscriptionConfiguration(backend: .parakeetV2)
        ) == "parakeet")
        #expect(await parakeet.transcriptionCount == 1)
        #expect(await appleSpeech.transcriptionCount == 0)

        let appleBackend = try router.backend(for: TranscriptionBackendSnapshot(
            backend: .appleSpeech,
            localeIdentifier: "en-US"
        ))
        #expect(try await appleBackend.transcribe(
            samples: [2],
            configuration: TranscriptionConfiguration(backend: .appleSpeech, localeIdentifier: "en-US")
        ) == "apple")
        #expect(await appleSpeech.transcriptionCount == 1)

        let noAppleRouter = TranscriptionBackendRouter(parakeetV2: parakeet)
        do {
            _ = try noAppleRouter.backend(for: TranscriptionBackendSnapshot(
                backend: .appleSpeech,
                localeIdentifier: "en-US"
            ))
            #expect(Bool(false), "Apple Speech must not silently fall back to Parakeet")
        } catch let error as TranscriptionBackendError {
            #expect(error == .unavailable(.appleSpeech))
        }
    }

    @Test("FluidAudio backend preserves prepare, transcribe, and cleanup boundaries")
    func fluidAudioBackendPreservesLifecycleBoundaries() async {
        let service = FluidAudioTranscriptionService(
            modelStore: FluidAudioModelStore(
                modelsExist: { _ in false },
                loadFromCache: { _ in
                    throw TestRecordingCaptureError.startFailed
                }
            )
        )

        let configuration = TranscriptionConfiguration(backend: .parakeetV2)
        #expect(!(await service.isPrepared(for: configuration)))

        do {
            try await service.prepare(configuration: configuration)
            #expect(Bool(false), "prepare should fail when Parakeet is not downloaded")
        } catch let error as FluidAudioTranscriptionServiceError {
            #expect(error == .modelNotDownloaded)
        } catch {
            #expect(Bool(false), "unexpected prepare error: \(error)")
        }

        do {
            _ = try await service.transcribe(samples: [0, 1])
            #expect(Bool(false), "transcribe should fail before loading a missing model")
        } catch let error as FluidAudioTranscriptionServiceError {
            #expect(error == .modelNotDownloaded)
        } catch {
            #expect(Bool(false), "unexpected transcription error: \(error)")
        }

        await service.cleanup()
        #expect(!(await service.isPrepared(for: configuration)))
    }

    @Test("Explicit model acquisition restores offline mode")
    @MainActor
    func explicitModelAcquisitionRestoresOfflineMode() async {
        FluidAudioNetworkPolicy.prohibitAutomaticDownloads()

        let networkWasEnabledInsideAction = await FluidAudioNetworkPolicy.performExplicitDownload {
            !DownloadUtils.enforceOffline
        }

        #expect(networkWasEnabledInsideAction)
        #expect(DownloadUtils.enforceOffline)
    }

    @Test("Failed model acquisition also restores offline mode")
    @MainActor
    func failedModelAcquisitionRestoresOfflineMode() async {
        FluidAudioNetworkPolicy.prohibitAutomaticDownloads()

        do {
            let _: Bool = try await FluidAudioNetworkPolicy.performExplicitDownload {
                throw TestModelDownloadError.failed
            }
            #expect(Bool(false), "the fake download should throw")
        } catch TestModelDownloadError.failed {
            // Expected test-only failure.
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        #expect(DownloadUtils.enforceOffline)
    }

    @Test("Recording gate distinguishes ready, downloading, and missing models")
    @MainActor
    func recordingGateReflectsModelAcquisitionState() {
        #expect(VoiceInkEngine.modelRecordingGate(isDownloading: false, isDownloaded: true) == .ready)
        #expect(VoiceInkEngine.modelRecordingGate(isDownloading: true, isDownloaded: true) == .downloading)
        #expect(VoiceInkEngine.modelRecordingGate(isDownloading: true, isDownloaded: false) == .downloading)
        #expect(VoiceInkEngine.modelRecordingGate(isDownloading: false, isDownloaded: false) == .missing)
    }

    @Test("Recording sample buffer enforces its byte limit")
    func recordingSampleBufferEnforcesByteLimit() {
        let buffer = RecordingSampleBuffer(maxBytes: 4)
        buffer.append(Data([0, 0, 0, 0]))
        #expect(buffer.snapshotFloatSamples().count == 2)

        buffer.append(Data([0, 0]))
        #expect(buffer.overflowed)
        #expect(buffer.snapshotFloatSamples().count == 2)
        #expect(buffer.takeFloatSamples().count == 2)
        #expect(buffer.snapshotFloatSamples().isEmpty)

        buffer.append(Data([0, 0]))
        buffer.discard()
        #expect(buffer.snapshotFloatSamples().isEmpty)
    }

    @Test("Recorder installs and clears the capture callback around a session")
    @MainActor
    func recorderOwnsCaptureLifecycle() async throws {
        let testDefaults = TestDefaults(deviceID: 77)
        defer { testDefaults.cleanup() }
        let capture = TestRecordingCapture()
        let recorder = Recorder(capture: capture, currentDeviceID: { 77 }, defaults: testDefaults.store)
        let outputURL = testOutputURL()
        recorder.onAudioChunk = { _ in }

        try await recorder.startRecording(toOutputFile: outputURL)
        try await Task.sleep(for: .milliseconds(40))
        #expect(recorder.audioMeter.averagePower > 0)
        await recorder.stopRecording()

        let events = await capture.events
        #expect(events.contains(.handlerInstalled))
        #expect(events.contains(.started(deviceID: 77)))
        #expect(events.contains(.stopped))
        #expect(events.last == .handlerCleared)
        #expect(recorder.onAudioChunk == nil)
        #expect(recorder.audioMeter == AudioMeter(averagePower: 0, peakPower: 0))

        await recorder.stopRecording()
        try await Task.sleep(for: .milliseconds(40))
        #expect(recorder.audioMeter == AudioMeter(averagePower: 0, peakPower: 0))
        #expect((await capture.events).filter { $0 == .stopped }.count == 2)
    }

    @Test("Recorder stops a failed capture before returning its start error")
    @MainActor
    func recorderCleansUpAfterStartFailure() async {
        let testDefaults = TestDefaults(deviceID: 88)
        defer { testDefaults.cleanup() }
        let capture = TestRecordingCapture(startError: TestRecordingCaptureError.startFailed)
        let recorder = Recorder(capture: capture, currentDeviceID: { 88 }, defaults: testDefaults.store)
        let outputURL = testOutputURL()

        do {
            try await recorder.startRecording(toOutputFile: outputURL)
            #expect(Bool(false), "startRecording should throw")
        } catch let error as Recorder.RecorderError {
            if case .couldNotStartRecording = error {
                // Expected error after the capture cleanup below.
            } else {
                #expect(Bool(false), "unexpected recorder error")
            }
        } catch {
            #expect(Bool(false), "unexpected error type: \(error)")
        }

        let events = await capture.events
        #expect(events.contains(.stopped))
        #expect(events.last == .handlerCleared)
        #expect(recorder.onAudioChunk == nil)
    }

    @Test("Recorder can retry after a one-shot start failure")
    @MainActor
    func recorderRetriesAfterStartFailure() async throws {
        let testDefaults = TestDefaults(deviceID: 66)
        defer { testDefaults.cleanup() }
        let capture = TestRecordingCapture(startError: TestRecordingCaptureError.startFailed)
        let recorder = Recorder(capture: capture, currentDeviceID: { 66 }, defaults: testDefaults.store)
        let outputURL = testOutputURL()

        do {
            try await recorder.startRecording(toOutputFile: outputURL)
            #expect(Bool(false), "first start should throw")
        } catch is Recorder.RecorderError {
            // Expected one-shot failure.
        }

        recorder.onAudioChunk = { _ in }
        try await recorder.startRecording(toOutputFile: outputURL)
        try await Task.sleep(for: .milliseconds(30))
        #expect(recorder.audioMeter.averagePower > 0)
        await recorder.stopRecording()

        let events = await capture.events
        #expect(events.filter { $0 == .started(deviceID: 66) }.count == 1)
        #expect(events.filter { $0 == .stopped }.count == 2)
        #expect(recorder.onAudioChunk == nil)
    }

    @Test("Recorder can run two sessions and leaves no meter task behind")
    @MainActor
    func recorderSupportsRepeatedSessions() async throws {
        let testDefaults = TestDefaults(deviceID: 55)
        defer { testDefaults.cleanup() }
        let capture = TestRecordingCapture()
        let recorder = Recorder(capture: capture, currentDeviceID: { 55 }, defaults: testDefaults.store)
        let outputURL = testOutputURL()

        for _ in 0..<2 {
            recorder.onAudioChunk = { _ in }
            try await recorder.startRecording(toOutputFile: outputURL)
            try await Task.sleep(for: .milliseconds(25))
            #expect(recorder.audioMeter.averagePower > 0)
            await recorder.stopRecording()
            #expect(recorder.audioMeter == AudioMeter(averagePower: 0, peakPower: 0))
        }

        try await Task.sleep(for: .milliseconds(40))
        #expect(recorder.audioMeter == AudioMeter(averagePower: 0, peakPower: 0))
        #expect((await capture.events).filter { $0 == .started(deviceID: 55) }.count == 2)
    }

    @Test("Recorder does not resurrect capture after a stop during start")
    @MainActor
    func recorderHonorsStopDuringStart() async throws {
        let testDefaults = TestDefaults(deviceID: 99)
        defer { testDefaults.cleanup() }
        let capture = TestRecordingCapture(suspendStart: true)
        let recorder = Recorder(capture: capture, currentDeviceID: { 99 }, defaults: testDefaults.store)
        recorder.onAudioChunk = { _ in }
        let outputURL = testOutputURL()

        let startTask = Task { @MainActor in
            try? await recorder.startRecording(toOutputFile: outputURL)
        }
        while !(await capture.startRequested) {
            try await Task.sleep(for: .milliseconds(1))
        }

        let stopTask = Task { @MainActor in
            await recorder.stopRecording()
        }
        await Task.yield()
        await capture.releaseStart()
        await startTask.value
        await stopTask.value

        #expect(recorder.audioMeter == AudioMeter(averagePower: 0, peakPower: 0))
        #expect((await capture.events).last == .handlerCleared)
        #expect(recorder.onAudioChunk == nil)
    }
}

private struct TestDefaults {
    let suiteName: String
    let store: UserDefaults

    init(deviceID: AudioDeviceID) {
        let suiteName = "com.prakashjoshipax.VoiceInkTests.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated test defaults")
        }
        self.suiteName = suiteName
        self.store = store
        store.removePersistentDomain(forName: suiteName)
        store.set(String(deviceID), forKey: "lastUsedMicrophoneDeviceID")
    }

    func cleanup() {
        store.removePersistentDomain(forName: suiteName)
    }
}

private struct TestSelectionDefaults {
    let suiteName: String
    let store: UserDefaults

    init() {
        let suiteName = "com.prakashjoshipax.VoiceInkTests.selection.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create isolated selection test defaults")
        }
        self.suiteName = suiteName
        self.store = store
        store.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        store.removePersistentDomain(forName: suiteName)
    }
}

private func testOutputURL() -> URL {
    URL(fileURLWithPath: "/dev/null")
}

@MainActor
private final class TestRecorderState: ObservableObject, RecorderStateProvider {
    @Published var recordingState: RecordingState = .idle
    @Published var partialTranscript = ""
}

private enum TestRecordingCaptureError: Error {
    case startFailed
}

private enum TestModelDownloadError: Error {
    case failed
}

private actor TestTranscriptionBackend: TranscriptionBackend {
    let result: String
    private(set) var transcriptionCount = 0
    private var prepared = false

    init(result: String) {
        self.result = result
    }

    func isPrepared(for configuration: TranscriptionConfiguration) -> Bool { prepared }

    func prepare(configuration: TranscriptionConfiguration) async throws {
        prepared = true
    }

    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> String {
        transcriptionCount += 1
        return result
    }

    func cleanup() async {
        prepared = false
    }
}

private actor TestModelLoader {
    private(set) var invocationCount = 0

    func load(_ version: AsrModelVersion) async throws -> AsrModels {
        invocationCount += 1
        throw TestRecordingCaptureError.startFailed
    }
}

private actor TestRecordingCapture: RecordingCapture {
    enum Event: Equatable {
        case handlerInstalled
        case handlerCleared
        case started(deviceID: AudioDeviceID)
        case stopped
    }

    private(set) var events: [Event] = []
    private var startError: Error?
    private let suspendStart: Bool
    private(set) var startRequested = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(startError: Error? = nil, suspendStart: Bool = false) {
        self.startError = startError
        self.suspendStart = suspendStart
    }

    func prepare(deviceID: AudioDeviceID) async throws {}

    func startRecording(
        toOutputFile url: URL,
        deviceID: AudioDeviceID,
        onAudioChunk: (@Sendable (Data) -> Void)?
    ) async throws {
        events.append(onAudioChunk == nil ? .handlerCleared : .handlerInstalled)
        startRequested = true
        if suspendStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        if let startError {
            self.startError = nil
            throw startError
        }
        events.append(.started(deviceID: deviceID))
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stopRecording() async {
        events.append(.stopped)
        events.append(.handlerCleared)
    }

    func teardown() async {}

    func switchDevice(to deviceID: AudioDeviceID) async throws {}

    func meter() async -> CaptureMeter {
        CaptureMeter(averagePower: -30, peakPower: -12)
    }
}
