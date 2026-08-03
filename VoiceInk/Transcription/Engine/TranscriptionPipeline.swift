import Foundation
import os

@MainActor
final class TranscriptionPipeline {
    private let fluidAudioService: FluidAudioTranscriptionService
    private let delivery: TranscriptionDelivery
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(fluidAudioService: FluidAudioTranscriptionService, delivery: TranscriptionDelivery) {
        self.fluidAudioService = fluidAudioService
        self.delivery = delivery
    }

    func run(
        samples: [Float],
        shouldCancel: () -> Bool,
        onDismiss: @escaping () async -> Void
    ) async throws {
        if shouldCancel() { return }

        let transcribeInterval = LeanSignpost.signposter.beginInterval("transcribe")
        var text = try await fluidAudioService.transcribe(samples: samples)
        LeanSignpost.signposter.endInterval("transcribe", transcribeInterval)
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
        TranscriptionLog.append(text: text)
    }
}
