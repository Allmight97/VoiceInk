import Foundation

enum ModelProvider: String, Codable, Hashable, CaseIterable {
    case fluidAudio = "Parakeet"
    case nativeApple = "Native Apple"
}

protocol TranscriptionModel: Identifiable, Hashable, Sendable {
    var id: UUID { get }
    var name: String { get }
    var displayName: String { get }
    var description: String { get }
    var provider: ModelProvider { get }
    var isMultilingualModel: Bool { get }
    var supportedLanguages: [String: String] { get }
}

extension TranscriptionModel {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var language: String {
        isMultilingualModel ? String(localized: "Multilingual") : String(localized: "English")
    }
}

struct NativeAppleModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .nativeApple
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
}

struct FluidAudioModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .fluidAudio
    let size: String
    let speed: Double
    let accuracy: Double
    let ramUsage: Double
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
}
