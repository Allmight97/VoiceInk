import Foundation
import Speech

/// Owns state observations and explicit acquisition for one locale at a time.
///
/// The transcription backend only calls `refresh`; acquisition and reservation
/// release are exposed separately for a future Settings surface. Asset
/// installation requests auto-reserve locales when needed. This manager does
/// not reserve on prepare or release on cleanup: subscriptions remain stable
/// until an explicit user action calls `release(locale:)`.
actor AppleSpeechAssetManager {
    private let boundary: any AppleSpeechAssetBoundary
    private var states: [String: AppleSpeechAssetState] = [:]

    init(boundary: any AppleSpeechAssetBoundary = SystemAppleSpeechAssetBoundary()) {
        self.boundary = boundary
    }

    func state(for locale: Locale) -> AppleSpeechAssetState? {
        states[locale.identifier]
    }

    func refresh(for locale: Locale) async -> AppleSpeechAssetState {
        let key = locale.identifier
        let status = await boundary.status(for: locale)
        let next = AppleSpeechAssetStateMachine.observed(status: status, previous: states[key])
        states[key] = next
        return next
    }

    func reservedLocales() async -> [Locale] {
        await boundary.reservedLocales()
    }

    /// Returns the locales currently supported by SpeechTranscriber.
    ///
    /// This is intentionally a read-only query. Settings calls it when the
    /// surface opens; no locale is reserved or installed by discovery.
    func supportedLocales() async -> [Locale] {
        await boundary.supportedLocales()
    }

    /// Finds the SpeechTranscriber locale that best matches a requested locale.
    /// The Speech framework owns the equivalence rules (language, script, and
    /// region), so callers do not need to duplicate them in the UI.
    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await boundary.supportedLocale(equivalentTo: locale)
    }

    /// Explicit user action that releases the app's reservation. This does not
    /// claim immediate deletion: the OS may remove assets at a later time.
    @discardableResult
    func release(locale: Locale) async -> Bool {
        await boundary.release(locale: locale)
    }

    /// Explicit acquisition entry point. `prepare` and `transcribe` do not
    /// call this method and therefore never request or download assets.
    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetState {
        let key = locale.identifier
        let current = await refresh(for: locale)
        guard current != .ready else { return current }
        guard current != .unsupported else { return current }

        states[key] = AppleSpeechAssetStateMachine.requested()

        do {
            guard let installation = try await boundary.requestInstallation(for: locale) else {
                let refreshed = await refresh(for: locale)
                return refreshed
            }

            states[key] = AppleSpeechAssetStateMachine.downloading(progress: installation.progress())
            try await installation.downloadAndInstall()
            return await refresh(for: locale)
        } catch {
            let failed = AppleSpeechAssetStateMachine.failed(error)
            states[key] = failed
            throw error
        }
    }

    func clearCachedState(for locale: Locale) {
        states.removeValue(forKey: locale.identifier)
    }
}

struct SystemAppleSpeechAssetBoundary: AppleSpeechAssetBoundary {
    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func status(for locale: Locale) async -> AppleSpeechAssetInventoryStatus {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        switch status {
        case .unsupported:
            return .unsupported
        case .downloading:
            return .downloading
        case .supported:
            return .supported
        case .installed:
            return .installed
        @unknown default:
            return .unsupported
        }
    }

    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetInstallation? {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return nil
        }

        return AppleSpeechAssetInstallation(
            progress: { request.progress.fractionCompleted },
            downloadAndInstall: { try await request.downloadAndInstall() }
        )
    }

    func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    func release(locale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: locale)
    }
}
