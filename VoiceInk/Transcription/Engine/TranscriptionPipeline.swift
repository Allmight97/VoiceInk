import Foundation
import os

@MainActor
final class TranscriptionPipeline {
    private let transcribe: ([Float]) async throws -> String
    private let delivery: TranscriptionDelivery
    private let appendLog: (String) -> Void
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    init(fluidAudioService: FluidAudioTranscriptionService, delivery: TranscriptionDelivery) {
        self.transcribe = { samples in
            try await fluidAudioService.transcribe(samples: samples)
        }
        self.delivery = delivery
        self.appendLog = { text in TranscriptionLog.append(text: text) }
    }

    init(
        transcribe: @escaping ([Float]) async throws -> String,
        delivery: TranscriptionDelivery,
        appendLog: @escaping (String) -> Void
    ) {
        self.transcribe = transcribe
        self.delivery = delivery
        self.appendLog = appendLog
    }

    func run(
        samples: [Float],
        isOperationCurrent: @escaping () -> Bool,
        onDismiss: @escaping () async -> Void
    ) async throws {
        guard isOperationCurrent() else { return }

        let transcribeInterval = LeanSignpost.signposter.beginInterval("transcribe")
        var text = try await transcribe(samples)
        LeanSignpost.signposter.endInterval("transcribe", transcribeInterval)
        guard isOperationCurrent() else { return }

        text = TranscriptionOutputFilter.filter(text)
        text = WordReplacementService.shared.applyReplacements(to: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            logger.notice("Skipping empty transcription delivery")
            if isOperationCurrent() {
                await onDismiss()
            }
            return
        }

        guard isOperationCurrent() else { return }
        await delivery.deliver(
            text: text,
            actions: TranscriptionDelivery.Actions(
                isOperationCurrent: isOperationCurrent,
                dismiss: {
                    if isOperationCurrent() {
                        await onDismiss()
                    }
                }
            )
        )
        if isOperationCurrent() {
            appendLog(text)
        }
    }

    static func isOperationCurrent(
        operationID: UUID,
        activeOperationID: UUID?,
        isCancelled: Bool
    ) -> Bool {
        activeOperationID == operationID && !isCancelled
    }
}
