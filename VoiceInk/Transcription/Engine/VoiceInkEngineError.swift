import Foundation

enum VoiceInkEngineError: Error, Identifiable {
    case modelLoadFailed
    case transcriptionFailed
    case unknownError

    var id: String { UUID().uuidString }
}

extension VoiceInkEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            return String(localized: "Failed to load the transcription model.")
        case .transcriptionFailed:
            return String(localized: "Failed to transcribe the audio.")
        case .unknownError:
            return String(localized: "An unknown error occurred.")
        }
    }
}
