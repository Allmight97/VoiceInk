import Foundation

/// The local transcription backends that VoiceInk can select.
///
/// This is intentionally closed. Adding a backend is a product decision that
/// must add an explicit route and its acquisition/runtime behavior.
enum TranscriptionBackendID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case parakeetV2 = "parakeet-v2"
    case appleSpeech = "apple-speech"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .parakeetV2:
            return String(localized: "Parakeet V2")
        case .appleSpeech:
            return String(localized: "Apple Speech")
        }
    }
}

/// The immutable backend and locale selected for one recording operation.
///
/// Apple Speech owns a locale; Parakeet V2 does not. A locale supplied for
/// Parakeet is deliberately discarded so a snapshot cannot carry an
/// inapplicable setting into that backend.
struct TranscriptionConfiguration: Equatable, Hashable, Sendable, Codable {
    let backend: TranscriptionBackendID
    let localeIdentifier: String?

    init(backend: TranscriptionBackendID, localeIdentifier: String? = nil) {
        self.backend = backend

        guard backend == .appleSpeech,
              let localeIdentifier,
              !localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.localeIdentifier = nil
            return
        }

        self.localeIdentifier = localeIdentifier
    }

    init(backend: TranscriptionBackendID, locale: Locale?) {
        self.init(backend: backend, localeIdentifier: locale?.identifier)
    }

    var locale: Locale? {
        guard let localeIdentifier else { return nil }
        return Locale(identifier: localeIdentifier)
    }
}

/// A value captured at recording start. Settings changes after this value is
/// created apply to the next recording, never to an operation already running.
struct TranscriptionBackendSnapshot: Equatable, Hashable, Sendable {
    let configuration: TranscriptionConfiguration

    init(configuration: TranscriptionConfiguration) {
        self.configuration = configuration
    }

    init(backend: TranscriptionBackendID, localeIdentifier: String? = nil) {
        self.init(configuration: TranscriptionConfiguration(
            backend: backend,
            localeIdentifier: localeIdentifier
        ))
    }

    var backend: TranscriptionBackendID { configuration.backend }
    var localeIdentifier: String? { configuration.localeIdentifier }
}

struct FluidAudioModel: Sendable {
    let name: String
    let displayName: String
}
