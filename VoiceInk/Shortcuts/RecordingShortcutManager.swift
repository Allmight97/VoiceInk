import Foundation

@MainActor
final class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            refreshShortcutMonitoring()
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .toggle:
                return String(localized: "Toggle")
            case .pushToTalk:
                return String(localized: "Push to Talk")
            }
        }
    }

    private weak var engine: VoiceInkEngine?
    private weak var recorderUIManager: RecorderUIManager?
    private let shortcutMonitor = ShortcutMonitor()
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager?
    private var shortcutChangeObserver: NSObjectProtocol?

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager

        let savedMode = UserDefaults.standard.string(forKey: "primaryRecordingShortcutMode")
        self.primaryRecordingShortcutMode = Mode(rawValue: savedMode ?? "") ?? .toggle

        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        refreshShortcutMonitoring()
    }

    func updateShortcutStatus() {
        objectWillChange.send()
        refreshShortcutMonitoring()
    }

    private func refreshShortcutMonitoring() {
        guard let shortcut = ShortcutStore.shortcut(for: .primaryRecording) else {
            shortcutMonitor.stop()
            return
        }

        shortcutMonitor.start(
            shortcuts: [.primaryRecording: shortcut],
            interruptibleActions: [.primaryRecording],
            onKeyDown: { [weak self] _, _ in
                Task(priority: .userInitiated) { @MainActor in
                    await self?.handleKeyDown()
                }
            },
            onKeyUp: { [weak self] _, _ in
                Task(priority: .userInitiated) { @MainActor in
                    await self?.handleKeyUp()
                }
            },
            onShortcutInterrupted: { [weak self] _, _ in
                Task(priority: .userInitiated) { @MainActor in
                    await self?.engine?.cancelRecording()
                }
            }
        )
    }

    private func handleKeyDown() async {
        switch primaryRecordingShortcutMode {
        case .toggle:
            await recorderUIManager?.toggleRecorderPanel()
        case .pushToTalk:
            if recorderUIManager?.isRecorderPanelVisible == false {
                StartStopSound.playStart()
                recorderUIManager?.isRecorderPanelVisible = true
            }
            await engine?.setPushToTalkRecording(isPressed: true)
        }
    }

    private func handleKeyUp() async {
        guard primaryRecordingShortcutMode == .pushToTalk else { return }
        await engine?.setPushToTalkRecording(isPressed: false)
    }

    isolated deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            shortcutMonitor.stop()
        }
    }
}
