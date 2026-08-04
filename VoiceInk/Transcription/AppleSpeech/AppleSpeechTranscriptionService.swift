import Foundation

enum AppleSpeechTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case unsupportedLocale(String)
    case assetsUnavailable(AppleSpeechAssetState)
    case audioFormatUnavailable
    case audioBufferUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return String(localized: "Apple Speech requires an explicit locale.")
        case .unsupportedLocale(let locale):
            return String(localized: "Apple Speech does not support the locale \(locale).")
        case .assetsUnavailable:
            return String(localized: "Apple Speech assets are not installed for this locale.")
        case .audioFormatUnavailable, .audioBufferUnavailable:
            return String(localized: "Apple Speech could not prepare the recording audio.")
        case .cancelled:
            return String(localized: "Apple Speech transcription was cancelled.")
        }
    }
}

actor AppleSpeechTranscriptionService: TranscriptionBackend {
    private let assets: AppleSpeechAssetManager
    private let analyzer: any AppleSpeechAnalyzerBoundary
    private var preparedLocaleIdentifier: String?
    private var activeOperationID: UUID?

    init(
        assets: AppleSpeechAssetManager = AppleSpeechAssetManager(),
        analyzer: any AppleSpeechAnalyzerBoundary = SystemAppleSpeechAnalyzerBoundary()
    ) {
        self.assets = assets
        self.analyzer = analyzer
    }

    func isPrepared(for configuration: TranscriptionConfiguration) async -> Bool {
        guard let locale = validatedLocale(for: configuration),
              preparedLocaleIdentifier == locale.identifier else {
            return false
        }
        return await assets.refresh(for: locale) == .ready
    }

    func prepare(configuration: TranscriptionConfiguration) async throws {
        let locale = try requireLocale(for: configuration)
        let state = await assets.refresh(for: locale)
        switch state {
        case .ready:
            preparedLocaleIdentifier = locale.identifier
        case .unsupported:
            throw AppleSpeechTranscriptionError.unsupportedLocale(locale.identifier)
        default:
            throw AppleSpeechTranscriptionError.assetsUnavailable(state)
        }
    }

    func transcribe(
        samples: [Float],
        configuration: TranscriptionConfiguration
    ) async throws -> String {
        let locale = try requireLocale(for: configuration)
        try await prepare(configuration: configuration)
        try Task.checkCancellation()
        guard !samples.isEmpty else { return "" }

        let operationID = UUID()
        activeOperationID = operationID
        await analyzer.cancel()

        do {
            let transcript = try await analyzer.transcribe(samples: samples, locale: locale)
            try Task.checkCancellation()
            guard activeOperationID == operationID else {
                throw AppleSpeechTranscriptionError.cancelled
            }

            activeOperationID = nil
            return transcript
        } catch is CancellationError {
            if activeOperationID == operationID { activeOperationID = nil }
            await analyzer.cancel()
            throw AppleSpeechTranscriptionError.cancelled
        } catch {
            if activeOperationID == operationID { activeOperationID = nil }
            await analyzer.cancel()
            throw error
        }
    }

    func cleanup() async {
        activeOperationID = nil
        preparedLocaleIdentifier = nil
        await analyzer.cancel()
    }

    private func validatedLocale(for configuration: TranscriptionConfiguration) -> Locale? {
        guard configuration.backend == .appleSpeech,
              let identifier = configuration.localeIdentifier,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Locale(identifier: identifier)
    }

    private func requireLocale(for configuration: TranscriptionConfiguration) throws -> Locale {
        guard let locale = validatedLocale(for: configuration) else {
            throw AppleSpeechTranscriptionError.invalidConfiguration
        }
        return locale
    }
}
