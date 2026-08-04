import Foundation

@MainActor
final class TranscriptionDelivery {
    struct Actions {
        let isOperationCurrent: () -> Bool
        let dismiss: () async -> Void
    }

    private let playStopSound: () -> Void
    private let paste: (String) async -> Void

    init(
        playStopSound: @escaping () -> Void = { StartStopSound.playStop() },
        paste: @escaping (String) async -> Void = { text in
            await CursorPaster.startPasteAtCursor(text).value
        }
    ) {
        self.playStopSound = playStopSound
        self.paste = paste
    }

    func deliver(text: String, actions: Actions) async {
        guard actions.isOperationCurrent() else { return }

        playStopSound()
        await actions.dismiss()
        guard actions.isOperationCurrent() else { return }

        let pasteInterval = LeanSignpost.signposter.beginInterval("paste")
        await paste(text)
        LeanSignpost.signposter.endInterval("paste", pasteInterval)
    }
}
