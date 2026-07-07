import Foundation

enum TranscriptionModelRegistry {
    static let parakeetV2 = FluidAudioModel(
        name: "parakeet-tdt-0.6b-v2",
        displayName: "Parakeet V2",
        description: "NVIDIA Parakeet V2 for fast local English dictation.",
        size: "474 MB",
        speed: 0.99,
        accuracy: 0.94,
        ramUsage: 0.8,
        isMultilingualModel: false,
        supportedLanguages: ["en": "English"]
    )

    static let appleSpeech = NativeAppleModel(
        name: "apple-speech",
        displayName: "Apple Speech",
        description: "Native Apple transcription, available only when the macOS 26 SpeechAnalyzer gate is enabled.",
        isMultilingualModel: true,
        supportedLanguages: ["en-US": "English"]
    )

    static var models: [any TranscriptionModel] {
        [parakeetV2, appleSpeech]
    }
}
