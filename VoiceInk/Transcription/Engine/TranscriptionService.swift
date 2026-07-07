import Foundation

struct TranscriptionRequestContext {
    let language: String?
    let prompt: String?

    static let leanDefault = TranscriptionRequestContext(language: "en", prompt: nil)
}

protocol TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String

    /// In-memory path: 16 kHz mono Float samples straight from the recorder.
    func transcribe(samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String
}

extension TranscriptionService {
    /// Compatibility bridge for engines that require file input: writes a
    /// temporary WAV, transcribes it, and always removes the temp file.
    func transcribe(samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-\(UUID().uuidString).wav")
        try WAVEncoder.write(samples: samples, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await transcribe(audioURL: tempURL, model: model, context: context)
    }
}
