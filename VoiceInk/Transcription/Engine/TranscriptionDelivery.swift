import Foundation

@MainActor
final class TranscriptionDelivery {
    struct Actions {
        let dismiss: () async -> Void
    }

    func deliver(text: String, actions: Actions) async {
        StartStopSound.playStop()
        await actions.dismiss()
        _ = await CursorPaster.startPasteAtCursor(text).value
    }
}
