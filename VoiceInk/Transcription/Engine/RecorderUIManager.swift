import Foundation
import SwiftUI
import os

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
final class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }
            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var miniRecorderWindowController: MiniRecorderWindowController?
    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderUIManager")

    init() {}

    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    private func showRecorderPanel() {
        guard let engine, let recorder else { return }

        if miniRecorderWindowController == nil {
            miniRecorderWindowController = MiniRecorderWindowController(
                engine: engine,
                recorder: recorder,
                onRecordButtonTapped: { [weak self] in
                    Task { @MainActor in
                        await self?.toggleRecorderPanel()
                    }
                },
                onCloseTapped: { [weak self] in
                    Task { @MainActor in
                        await self?.closeRecorderPanel()
                    }
                }
            )
        }

        miniRecorderWindowController?.show()
    }

    private func hideRecorderPanel() {
        miniRecorderWindowController?.hide()
    }

    func toggleRecorderPanel() async {
        guard let engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording, .starting:
                await engine.toggleRecord()
            case .transcribing:
                await cancelRecording()
            case .idle:
                await dismissRecorderPanel()
            }
        } else {
            StartStopSound.playStart()
            isRecorderPanelVisible = true
            await engine.toggleRecord()
        }
    }

    func dismissRecorderPanel() async {
        hideRecorderPanel()
        isRecorderPanelVisible = false
    }

    private func closeRecorderPanel() async {
        await Self.performCloseAction(
            recordingState: engine?.recordingState ?? .idle,
            cancel: { [weak engine] in await engine?.cancelRecording() },
            dismiss: { [weak self] in await self?.dismissRecorderPanel() }
        )
    }

    static func performCloseAction(
        recordingState: RecordingState,
        cancel: () async -> Void,
        dismiss: () async -> Void
    ) async {
        if recordingState == .idle {
            await dismiss()
        } else {
            await cancel()
        }
    }

    func resetOnLaunch() async {
        logger.notice("Resetting recording state on launch")
        await engine?.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
    }

    func cancelRecording() async {
        await engine?.cancelRecording()
        await dismissRecorderPanel()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
    }

    @objc private func handleToggleRecorderPanelNotification() {
        Task { @MainActor in
            await toggleRecorderPanel()
        }
    }

    @objc private func handleDismissRecorderPanelNotification() {
        Task { @MainActor in
            await dismissRecorderPanel()
        }
    }
}
