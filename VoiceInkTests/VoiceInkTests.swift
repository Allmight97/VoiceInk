import Testing
import Foundation
import CoreAudio
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
            (.transcribing, "Transcribing", "Start Dictation", true, "Transcribing recording", true),
            (.enhancing, "Processing", "Start Dictation", false, "Processing recording", true),
            (.busy, "Busy", "Start Dictation", false, "Recorder unavailable", true)
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
