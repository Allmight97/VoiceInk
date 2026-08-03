import Foundation
import AVFoundation
import CoreAudio
import os

struct CaptureMeter: Sendable, Equatable {
    let averagePower: Float
    let peakPower: Float
}

protocol RecordingCapture: Sendable {
    func prepare(deviceID: AudioDeviceID) async throws
    func startRecording(
        toOutputFile url: URL,
        deviceID: AudioDeviceID,
        onAudioChunk: (@Sendable (Data) -> Void)?
    ) async throws
    func stopRecording() async
    func teardown() async
    func switchDevice(to deviceID: AudioDeviceID) async throws
    func meter() async -> CaptureMeter
}

actor CaptureSession: RecordingCapture {
    private let recorder: CoreAudioRecorder
    private var isRecording = false

    init(recorder: CoreAudioRecorder = CoreAudioRecorder()) {
        self.recorder = recorder
    }

    func prepare(deviceID: AudioDeviceID) async throws {
        guard !isRecording else { return }
        try recorder.prepare(deviceID: deviceID)
    }

    func startRecording(
        toOutputFile url: URL,
        deviceID: AudioDeviceID,
        onAudioChunk: (@Sendable (Data) -> Void)?
    ) async throws {
        recorder.onAudioChunk = onAudioChunk
        do {
            try recorder.startRecording(toOutputFile: url, deviceID: deviceID)
            isRecording = true
        } catch {
            recorder.onAudioChunk = nil
            throw error
        }
    }

    func stopRecording() async {
        recorder.stopRecording()
        isRecording = false
        recorder.onAudioChunk = nil
    }

    func teardown() async {
        recorder.teardown()
        isRecording = false
        recorder.onAudioChunk = nil
    }

    func switchDevice(to deviceID: AudioDeviceID) async throws {
        guard isRecording else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }
        try recorder.switchDevice(to: deviceID)
    }

    func meter() async -> CaptureMeter {
        CaptureMeter(
            averagePower: recorder.averagePower,
            peakPower: recorder.peakPower
        )
    }
}

@MainActor
class Recorder: NSObject, ObservableObject {
    private let capture: any RecordingCapture
    private let currentDeviceID: () -> AudioDeviceID
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var audioDeviceChangedObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private var lifecycleGeneration = 0
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterTask: Task<Void, Never>?
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0

    /// Audio chunk callback for streaming. The capture actor snapshots it
    /// immediately before a recording starts.
    var onAudioChunk: (@Sendable (_ data: Data) -> Void)?
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }
    
    init(
        capture: any RecordingCapture = CaptureSession(),
        currentDeviceID: @escaping () -> AudioDeviceID = { AudioDeviceManager.shared.getCurrentDevice() },
        defaults: UserDefaults = .standard
    ) {
        self.capture = capture
        self.currentDeviceID = currentDeviceID
        self.defaults = defaults
        super.init()
        setupDeviceSwitchObserver()
        setupAudioDeviceChangedObserver()
        schedulePrepareForCurrentDevice(reason: "init")
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let newDeviceID = notification.userInfo?["newDeviceID"] as? AudioDeviceID
            Task { @MainActor in
                await self?.handleDeviceSwitchRequired(newDeviceID: newDeviceID)
            }
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "device-changed")
            }
        }
    }

    private func handleDeviceSwitchRequired(newDeviceID: AudioDeviceID?) async {
        guard !isReconfiguring else { return }
        guard deviceManager.isRecordingActive else { return }
        guard let newDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await capture.switchDevice(to: newDeviceID)

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Switched to: %@"), deviceName),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error, privacy: .public)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        deviceManager.isRecordingActive = true

        let currentDeviceID = currentDeviceID()
        let lastDeviceID = defaults.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Using: %@"), deviceName),
                    type: .info
                )
            }
        }
        defaults.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let deviceID = currentDeviceID

        do {
            try await capture.startRecording(
                toOutputFile: url,
                deviceID: deviceID,
                onAudioChunk: onAudioChunk
            )
            guard lifecycleGeneration == generation, deviceManager.isRecordingActive else {
                // A stop or cancellation arrived while capture was starting.
                await capture.stopRecording()
                return
            }
            startAudioMeterTask()
        } catch {
            guard lifecycleGeneration == generation, deviceManager.isRecordingActive else {
                await capture.stopRecording()
                return
            }
            logger.error("Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)")
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        lifecycleGeneration += 1
        audioMeterTask?.cancel()
        audioMeterTask = nil

        await capture.stopRecording()
        onAudioChunk = nil

        smoothedAverage = 0
        smoothedPeak = 0

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
        deviceManager.isRecordingActive = false
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error, privacy: .public)")

        // Stop the recording
        await stopRecording()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Recording Failed: %@"), error.localizedDescription),
                type: .error
            )
        }
    }

    private func startAudioMeterTask() {
        audioMeterTask?.cancel()
        let capture = self.capture
        audioMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let meter = await capture.meter()
                guard !Task.isCancelled else { return }
                self?.updateAudioMeter(from: meter)

                do {
                    try await Task.sleep(for: .milliseconds(17))
                } catch {
                    return
                }
            }
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = currentDeviceID()
        guard deviceID != 0 else {
            Task { await capture.teardown() }
            return
        }

        let capture = self.capture
        Task { @MainActor [weak self, capture] in
            do {
                try await capture.prepare(deviceID: deviceID)
            } catch {
                self?.logger.warning("Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)")
            }
        }
    }

    private func updateAudioMeter(from meter: CaptureMeter) {
        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if meter.averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if meter.averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (meter.averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if meter.peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if meter.peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (meter.peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // The task and publication both run on the main actor; no lock or
        // cross-queue UI hop is needed.
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        audioMeter = AudioMeter(averagePower: Double(smoothedAverage), peakPower: Double(smoothedPeak))
    }
    
    // MARK: - Cleanup

    isolated deinit {
        audioMeterTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let capture = self.capture
        Task { await capture.teardown() }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
