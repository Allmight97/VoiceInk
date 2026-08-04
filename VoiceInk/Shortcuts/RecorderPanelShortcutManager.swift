import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class RecorderPanelShortcutManager: ObservableObject {
    private var recorderUIManager: RecorderUIManager
    private var visibilityTask: Task<Void, Never>?
    private let visibleRecorderMonitor = ShortcutMonitor()
    private var firstEscapePressTime: Date?
    private let escapeDoublePressThreshold: TimeInterval = 1.5
    private var escapeTimeoutTask: Task<Void, Never>?

    init(recorderUIManager: RecorderUIManager) {
        self.recorderUIManager = recorderUIManager
        setupVisibilityObserver()
    }

    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in recorderUIManager.$isRecorderPanelVisible.values {
                if isVisible {
                    refreshVisibleShortcuts()
                } else {
                    visibleRecorderMonitor.stop()
                    resetEscapeState()
                }
            }
        }
    }

    private func refreshVisibleShortcuts() {
        guard recorderUIManager.isRecorderPanelVisible else {
            visibleRecorderMonitor.stop()
            resetEscapeState()
            return
        }

        visibleRecorderMonitor.start(
            shortcuts: [
                .recorderPanelEscape: .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
            ],
            onKeyDown: { [weak self] action, _ in
                Task { @MainActor in
                    await self?.handleRecorderPanelShortcut(action)
                }
            },
            onKeyUp: { _, _ in }
        )
    }

    private func handleRecorderPanelShortcut(_ action: ShortcutAction) async {
        guard recorderUIManager.isRecorderPanelVisible,
              action == .recorderPanelEscape else { return }
        await handleEscapeShortcut()
    }

    private func handleEscapeShortcut() async {
        let now = Date()
        if let firstTime = firstEscapePressTime,
           now.timeIntervalSince(firstTime) <= escapeDoublePressThreshold {
            resetEscapeState()
            await recorderUIManager.cancelRecording()
            return
        }

        firstEscapePressTime = now
        NotificationManager.shared.showNotification(
            title: String(localized: "Press Esc again to cancel"),
            type: .info,
            duration: escapeDoublePressThreshold
        )
        escapeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.escapeDoublePressThreshold ?? 1.5) * 1_000_000_000))
            await MainActor.run {
                self?.firstEscapePressTime = nil
            }
        }
    }

    private func resetEscapeState() {
        firstEscapePressTime = nil
        escapeTimeoutTask?.cancel()
        escapeTimeoutTask = nil
    }

    isolated deinit {
        visibilityTask?.cancel()
        MainActor.assumeIsolated {
            visibleRecorderMonitor.stop()
            resetEscapeState()
        }
    }
}
