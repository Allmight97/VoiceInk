import Foundation

struct TranscriptionRequestContext {
    let language: String?
    let prompt: String?

    static let leanDefault = TranscriptionRequestContext(language: "en", prompt: nil)
}

protocol TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String
}
