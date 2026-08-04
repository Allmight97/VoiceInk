import Foundation
import Speech

/// The observed state of the system-owned Apple Speech assets for one locale.
///
/// `supported` in the Speech framework means that the locale can be installed;
/// it does not mean that its assets are present. A previously ready locale can
/// therefore become `reclaimed` when the OS evicts its assets.
enum AppleSpeechAssetState: Equatable, Sendable {
    case unsupported
    case absent
    case requested
    case downloading(progress: Double?)
    case ready
    case reservationLimit
    case failed(message: String)
    case reclaimed
}

enum AppleSpeechAssetInventoryStatus: Equatable, Sendable {
    case unsupported
    case downloading
    case supported
    case installed
}

enum AppleSpeechAssetStateMachine {
    static func observed(
        status: AppleSpeechAssetInventoryStatus,
        previous: AppleSpeechAssetState?
    ) -> AppleSpeechAssetState {
        switch status {
        case .unsupported:
            return .unsupported
        case .downloading:
            return .downloading(progress: nil)
        case .installed:
            return .ready
        case .supported:
            if previous == .ready {
                return .reclaimed
            }
            return .absent
        }
    }

    static func requested() -> AppleSpeechAssetState {
        .requested
    }

    static func downloading(progress: Double?) -> AppleSpeechAssetState {
        .downloading(progress: progress)
    }

    static func failed(_ error: Error) -> AppleSpeechAssetState {
        let cocoaError = error as NSError
        if cocoaError.domain == SFSpeechError.errorDomain,
           cocoaError.code == SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue {
            return .reservationLimit
        }
        return .failed(message: String(describing: error))
    }
}

struct AppleSpeechAssetInstallation: Sendable {
    let progress: @Sendable () -> Double?
    let downloadAndInstall: @Sendable () async throws -> Void

    init(
        progress: @escaping @Sendable () -> Double?,
        downloadAndInstall: @escaping @Sendable () async throws -> Void
    ) {
        self.progress = progress
        self.downloadAndInstall = downloadAndInstall
    }
}

protocol AppleSpeechAssetBoundary: Sendable {
    func status(for locale: Locale) async -> AppleSpeechAssetInventoryStatus
    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetInstallation?
    func reservedLocales() async -> [Locale]
    func release(locale: Locale) async -> Bool
}
