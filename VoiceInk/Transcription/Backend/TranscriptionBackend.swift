import Foundation

/// The small runtime seam shared by the local transcription adapters.
///
/// Acquisition is intentionally absent. Backend preparation may load already
/// acquired resources, but transcription never downloads or otherwise acquires
/// a model. Explicit acquisition remains owned by the corresponding Settings
/// surface.
protocol TranscriptionBackend: Sendable {
    func isPrepared(for configuration: TranscriptionConfiguration) async -> Bool
    func prepare(configuration: TranscriptionConfiguration) async throws
    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> String
    func cleanup() async
}

/// Routes the two product-owned backends without a provider/plugin registry.
struct TranscriptionBackendRouter: Sendable {
    private let parakeetV2: any TranscriptionBackend
    private let appleSpeech: any TranscriptionBackend

    init(
        parakeetV2: any TranscriptionBackend,
        appleSpeech: any TranscriptionBackend
    ) {
        self.parakeetV2 = parakeetV2
        self.appleSpeech = appleSpeech
    }

    func backend(for configuration: TranscriptionConfiguration) -> any TranscriptionBackend {
        switch configuration.backend {
        case .parakeetV2:
            return parakeetV2
        case .appleSpeech:
            return appleSpeech
        }
    }
}

/// Injected persistence for the selected backend and Apple locale.
///
/// Settings and the recording engine are main-actor owned, so this storage
/// boundary is main-actor isolated. The resulting configuration is a Sendable
/// value and can safely cross into backend actors.
@MainActor
protocol TranscriptionSelectionStorage {
    func load() -> TranscriptionConfiguration
}

@MainActor
final class UserDefaultsTranscriptionSelectionStorage: TranscriptionSelectionStorage {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> TranscriptionConfiguration {
        let rawBackend = defaults.string(forKey: AppDefaults.transcriptionBackend)
        let backend: TranscriptionBackendID

        if let rawBackend, let storedBackend = TranscriptionBackendID(rawValue: rawBackend) {
            backend = storedBackend
        } else {
            backend = .parakeetV2
            // Persist both missing and invalid values so the migration is
            // stable even when the application did not register defaults.
            defaults.set(backend.rawValue, forKey: AppDefaults.transcriptionBackend)
        }

        return TranscriptionConfiguration(
            backend: backend,
            localeIdentifier: defaults.string(forKey: AppDefaults.appleSpeechLocale)
        )
    }
}
