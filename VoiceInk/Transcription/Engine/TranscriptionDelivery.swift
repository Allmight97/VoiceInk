import Foundation

@MainActor
final class TranscriptionDelivery {
    struct Actions {
        let dismiss: () async -> Void
    }

    func deliver(text: String, actions: Actions) async {
        StartStopSound.playStop()
        await actions.dismiss()
        let pasteInterval = LeanSignpost.signposter.beginInterval("paste")
        _ = await CursorPaster.startPasteAtCursor(text).value
        LeanSignpost.signposter.endInterval("paste", pasteInterval)
    }
}
