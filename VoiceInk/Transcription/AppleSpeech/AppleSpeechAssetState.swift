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
    func supportedLocales() async -> [Locale]
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?
    func status(for locale: Locale) async -> AppleSpeechAssetInventoryStatus
    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetInstallation?
    func reservedLocales() async -> [Locale]
    func release(locale: Locale) async -> Bool
}

extension AppleSpeechAssetBoundary {
    /// Test and embedded boundaries can opt out of locale discovery while
    /// retaining the asset status/acquisition seam.
    func supportedLocales() async -> [Locale] { [] }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? { nil }
}

enum AppleSpeechAssetPresentationStatus: Equatable, Sendable {
    case checking
    case downloadRequired
    case downloading
    case ready
    case unsupported
    case reservationLimit
    case failed
}

enum AppleSpeechAssetPresentationAction: Equatable, Sendable {
    case none
    case download
    case releaseReservation
}

struct AppleSpeechAssetPresentation: Equatable, Sendable {
    let status: AppleSpeechAssetPresentationStatus
    let action: AppleSpeechAssetPresentationAction

    static func forState(_ state: AppleSpeechAssetState?) -> Self {
        switch state {
        case nil, .requested:
            return Self(status: .checking, action: .none)
        case .unsupported:
            return Self(status: .unsupported, action: .none)
        case .absent, .reclaimed:
            return Self(status: .downloadRequired, action: .download)
        case .downloading:
            return Self(status: .downloading, action: .none)
        case .ready:
            return Self(status: .ready, action: .none)
        case .reservationLimit:
            return Self(status: .reservationLimit, action: .releaseReservation)
        case .failed:
            return Self(status: .failed, action: .download)
        }
    }
}
