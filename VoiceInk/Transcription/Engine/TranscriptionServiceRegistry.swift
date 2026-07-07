import Foundation
import os

@MainActor
final class TranscriptionServiceRegistry {
    let fluidAudioTranscriptionService: FluidAudioTranscriptionService
    private let nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")

    init(fluidAudioTranscriptionService: FluidAudioTranscriptionService = FluidAudioTranscriptionService()) {
        self.fluidAudioTranscriptionService = fluidAudioTranscriptionService
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext = .leanDefault
    ) async throws -> String {
        let service = service(for: model.provider)
        logger.debug("Transcribing with \(model.displayName, privacy: .public)")
        return try await service.transcribe(audioURL: audioURL, model: model, context: context)
    }

    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
    }
}
