import Foundation
import os

@MainActor
final class TranscriptionPipeline {
    private let serviceRegistry: TranscriptionServiceRegistry
    private let delivery: TranscriptionDelivery
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(serviceRegistry: TranscriptionServiceRegistry, delivery: TranscriptionDelivery) {
        self.serviceRegistry = serviceRegistry
        self.delivery = delivery
    }

    func run(
        audioURL: URL,
        model: any TranscriptionModel,
        shouldCancel: () -> Bool,
        onDismiss: @escaping () async -> Void
    ) async throws {
        if shouldCancel() { return }

        var text = try await serviceRegistry.transcribe(
            audioURL: audioURL,
            model: model,
            context: .leanDefault
        )
        if shouldCancel() { return }

        text = TranscriptionOutputFilter.filter(text)
        text = WordReplacementService.shared.applyReplacements(to: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            logger.notice("Skipping empty transcription delivery")
            await onDismiss()
            return
        }

        await delivery.deliver(
            text: text,
            actions: TranscriptionDelivery.Actions(dismiss: onDismiss)
        )
    }
}
