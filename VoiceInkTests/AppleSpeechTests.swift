import Foundation
import Speech
import Testing
@testable import VoiceInk

@Suite(.serialized)
struct AppleSpeechTests {
    @Test("Asset state distinguishes unsupported, absent, ready, and reclaimed")
    func assetStateMapping() {
        #expect(AppleSpeechAssetStateMachine.observed(status: .unsupported, previous: nil) == .unsupported)
        #expect(AppleSpeechAssetStateMachine.observed(status: .supported, previous: nil) == .absent)
        #expect(AppleSpeechAssetStateMachine.observed(status: .installed, previous: .absent) == .ready)
        #expect(AppleSpeechAssetStateMachine.observed(status: .supported, previous: .ready) == .reclaimed)
        #expect(AppleSpeechAssetStateMachine.observed(status: .downloading, previous: .absent) == .downloading)
    }

    @Test("Asset request transitions are explicit")
    func assetRequestTransitions() {
        #expect(AppleSpeechAssetStateMachine.requested() == .requested)
        #expect(AppleSpeechAssetStateMachine.downloading() == .downloading)
    }

    @Test("Asset presentation maps every state to a truthful status and action")
    func assetPresentationMapping() {
        #expect(AppleSpeechAssetPresentation.forState(nil) ==
            AppleSpeechAssetPresentation(status: .checking, action: .none))
        #expect(AppleSpeechAssetPresentation.forState(.requested) ==
            AppleSpeechAssetPresentation(status: .checking, action: .none))
        #expect(AppleSpeechAssetPresentation.forState(.absent) ==
            AppleSpeechAssetPresentation(status: .downloadRequired, action: .download))
        #expect(AppleSpeechAssetPresentation.forState(.reclaimed) ==
            AppleSpeechAssetPresentation(status: .downloadRequired, action: .download))
        #expect(AppleSpeechAssetPresentation.forState(.downloading) ==
            AppleSpeechAssetPresentation(status: .downloading, action: .none))
        #expect(AppleSpeechAssetPresentation.forState(.ready) ==
            AppleSpeechAssetPresentation(status: .ready, action: .none))
        #expect(AppleSpeechAssetPresentation.forState(.unsupported) ==
            AppleSpeechAssetPresentation(status: .unsupported, action: .none))
        #expect(AppleSpeechAssetPresentation.forState(.reservationLimit) ==
            AppleSpeechAssetPresentation(status: .reservationLimit, action: .releaseReservation))
        #expect(AppleSpeechAssetPresentation.forState(.failed(message: "network")) ==
            AppleSpeechAssetPresentation(status: .failed, action: .download))
    }

    @Test("Locale presentation sorts by localized name and falls back to identifier")
    func localePresentationOrderingAndFallback() {
        let displayLocale = Locale(identifier: "en-US")
        let locales = [
            Locale(identifier: "zz-ZZ"),
            Locale(identifier: "fr-FR"),
            Locale(identifier: "en-US"),
            Locale(identifier: "zz-AA")
        ]

        let sorted = AppleSpeechLocalePresentation.sorted(locales, displayLocale: displayLocale)
        #expect(sorted.map(\.identifier) == ["en-US", "fr-FR", "zz-AA", "zz-ZZ"])
        #expect(AppleSpeechLocalePresentation.displayName(
            for: Locale(identifier: "zz-ZZ"),
            in: displayLocale
        ) == "zz-ZZ")
        #expect(AppleSpeechLocalePresentation.initialLocaleIdentifier(
            storedIdentifier: nil,
            equivalentCurrentLocale: Locale(identifier: "en-US")
        ) == "en-US")
        #expect(AppleSpeechLocalePresentation.initialLocaleIdentifier(
            storedIdentifier: "fr-FR",
            equivalentCurrentLocale: Locale(identifier: "en-US")
        ) == "fr-FR")
        #expect(AppleSpeechLocalePresentation.initialLocaleIdentifier(
            storedIdentifier: "  ",
            equivalentCurrentLocale: nil
        ) == nil)
        #expect(AppleSpeechLocalePresentation.initialLocaleIdentifier(
            storedIdentifier: nil,
            equivalentCurrentLocale: nil
        ) == nil)
    }

    @Test("Locale discovery is read-only and supports current-locale equivalence")
    func supportedLocaleDiscoveryIsReadOnly() async {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        let equivalent = Locale(identifier: "en-US")
        let boundary = FakeAppleSpeechAssetBoundary(
            status: .supported,
            supportedLocales: supported,
            equivalentLocale: equivalent
        )
        let manager = AppleSpeechAssetManager(boundary: boundary)

        #expect(await manager.supportedLocales() == supported)
        #expect(await manager.supportedLocale(equivalentTo: Locale(identifier: "en-GB")) == equivalent)
        #expect(await boundary.supportedLocalesReadCount == 1)
        #expect(await boundary.supportedLocaleReadCount == 1)
        #expect(await boundary.requestCount == 0)
        #expect(await boundary.releaseCount == 0)
    }

    @Test("Asset acquisition records failure without claiming installation")
    func assetAcquisitionFailure() async {
        let boundary = FakeAppleSpeechAssetBoundary(status: .supported, installationError: FakeAssetError.failed)
        let manager = AppleSpeechAssetManager(boundary: boundary)
        let locale = Locale(identifier: "en-US")

        do {
            _ = try await manager.requestInstallation(for: locale)
            #expect(Bool(false), "acquisition should fail")
        } catch is FakeAssetError {
            // Expected test-only failure.
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        #expect(await manager.state(for: locale) == .failed(message: "failed"))
        #expect(await boundary.requestCount == 1)
    }

    @Test("Explicit acquisition reaches ready only after the fake install finishes")
    func explicitAssetAcquisition() async throws {
        let boundary = FakeAppleSpeechAssetBoundary(status: .supported)
        let manager = AppleSpeechAssetManager(boundary: boundary)
        let locale = Locale(identifier: "en-US")

        #expect(try await manager.requestInstallation(for: locale) == .ready)
        #expect(await manager.state(for: locale) == .ready)
        #expect(await boundary.requestCount == 1)
    }

    @Test("Speech reservation exhaustion has a distinct recovery state")
    func reservationLimitMapping() {
        let error = NSError(
            domain: SFSpeechError.errorDomain,
            code: SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue
        )

        #expect(AppleSpeechAssetStateMachine.failed(error) == .reservationLimit)
    }

    @Test("Installed assets prepare and transcribe without acquisition")
    func installedAssetsTranscribeWithoutAcquisition() async throws {
        let boundary = FakeAppleSpeechAssetBoundary(status: .installed)
        let analyzer = FakeAppleSpeechAnalyzerBoundary(result: "hello")
        let service = AppleSpeechTranscriptionService(
            assets: AppleSpeechAssetManager(boundary: boundary),
            analyzer: analyzer
        )
        let configuration = TranscriptionConfiguration(backend: .appleSpeech, localeIdentifier: "en-US")

        try await service.prepare(configuration: configuration)
        #expect(await service.isPrepared(for: configuration))
        #expect(try await service.transcribe(samples: [0.1, 0.2], configuration: configuration) == "hello")
        #expect(await boundary.requestCount == 0)
        #expect(await boundary.releaseCount == 0)
        #expect(await analyzer.samples == [0.1, 0.2])
    }

    @Test("Prepare and transcribe never request absent assets")
    func absentAssetsNeverAcquireImplicitly() async {
        let boundary = FakeAppleSpeechAssetBoundary(status: .supported)
        let analyzer = FakeAppleSpeechAnalyzerBoundary()
        let service = AppleSpeechTranscriptionService(
            assets: AppleSpeechAssetManager(boundary: boundary),
            analyzer: analyzer
        )
        let configuration = TranscriptionConfiguration(
            backend: .appleSpeech,
            localeIdentifier: "en-US"
        )

        do {
            try await service.prepare(configuration: configuration)
            #expect(Bool(false), "absent assets must fail preparation")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .assetsUnavailable(.absent))
        } catch {
            #expect(Bool(false), "unexpected preparation error: \(error)")
        }

        do {
            _ = try await service.transcribe(samples: [0.1], configuration: configuration)
            #expect(Bool(false), "absent assets must fail transcription")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .assetsUnavailable(.absent))
        } catch {
            #expect(Bool(false), "unexpected transcription error: \(error)")
        }

        #expect(await boundary.requestCount == 0)
        #expect(await analyzer.invocationCount == 0)
    }

    @Test("Empty input returns no text without starting analysis")
    func emptyInputDoesNotStartAnalyzer() async throws {
        let boundary = FakeAppleSpeechAssetBoundary(status: .installed)
        let analyzer = FakeAppleSpeechAnalyzerBoundary()
        let service = AppleSpeechTranscriptionService(
            assets: AppleSpeechAssetManager(boundary: boundary),
            analyzer: analyzer
        )
        let configuration = TranscriptionConfiguration(
            backend: .appleSpeech,
            localeIdentifier: "en-US"
        )

        #expect(try await service.transcribe(samples: [], configuration: configuration).isEmpty)
        #expect(await analyzer.invocationCount == 0)
        #expect(await boundary.requestCount == 0)
    }

    @Test("Reservation release is explicit and never part of backend cleanup")
    func explicitReservationRelease() async {
        let boundary = FakeAppleSpeechAssetBoundary(status: .installed)
        let manager = AppleSpeechAssetManager(boundary: boundary)
        let locale = Locale(identifier: "en-US")

        #expect(await manager.reservedLocales() == [locale])
        #expect(await boundary.reservedLocalesReadCount == 1)
        #expect(await boundary.releaseCount == 0)

        #expect(await manager.release(locale: locale))
        #expect(await boundary.releaseCount == 1)
    }

    @Test("Unsupported locale and missing explicit locale fail validation")
    func localeAndConfigurationValidation() async {
        let unsupportedBoundary = FakeAppleSpeechAssetBoundary(status: .unsupported)
        let service = AppleSpeechTranscriptionService(
            assets: AppleSpeechAssetManager(boundary: unsupportedBoundary),
            analyzer: FakeAppleSpeechAnalyzerBoundary()
        )

        do {
            try await service.prepare(configuration: TranscriptionConfiguration(
                backend: .appleSpeech,
                localeIdentifier: "zz-ZZ"
            ))
            #expect(Bool(false), "unsupported locale should fail")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .unsupportedLocale("zz-ZZ"))
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        do {
            try await service.prepare(configuration: TranscriptionConfiguration(backend: .appleSpeech))
            #expect(Bool(false), "missing locale should fail")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .invalidConfiguration)
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }

        do {
            try await service.prepare(configuration: TranscriptionConfiguration(backend: .parakeetV2))
            #expect(Bool(false), "non-Apple configuration should fail")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .invalidConfiguration)
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
    }

    @Test("Only finalized results are returned in emission order")
    func finalTailAggregation() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.append(text: "volatile", isFinal: false)
        accumulator.append(text: "hello", isFinal: true)
        accumulator.append(text: "world!", isFinal: true)

        #expect(accumulator.finalText == "hello world!")
    }

    @Test("Cancellation stops the analyzer and suppresses its stale result")
    func cancellationSuppressesStaleResult() async {
        let boundary = FakeAppleSpeechAssetBoundary(status: .installed)
        let analyzer = BlockingAppleSpeechAnalyzerBoundary()
        let service = AppleSpeechTranscriptionService(
            assets: AppleSpeechAssetManager(boundary: boundary),
            analyzer: analyzer
        )
        let configuration = TranscriptionConfiguration(backend: .appleSpeech, localeIdentifier: "en-US")
        let task = Task {
            try await service.transcribe(samples: [0, 1, 2], configuration: configuration)
        }

        while await analyzer.invocationCount == 0 {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "cancelled operation should not return text")
        } catch let error as AppleSpeechTranscriptionError {
            #expect(error == .cancelled)
        } catch {
            #expect(Bool(false), "unexpected error: \(error)")
        }
        #expect(await analyzer.cancelCount > 0)
    }
}

private enum FakeAssetError: Error, Equatable {
    case failed
}

private actor FakeAppleSpeechAssetBoundary: AppleSpeechAssetBoundary {
    var statusValue: AppleSpeechAssetInventoryStatus
    let installationError: Error?
    let supportedLocalesValue: [Locale]
    let equivalentLocale: Locale?
    private(set) var requestCount = 0
    private(set) var reservedLocalesReadCount = 0
    private(set) var releaseCount = 0
    private(set) var supportedLocalesReadCount = 0
    private(set) var supportedLocaleReadCount = 0

    init(
        status: AppleSpeechAssetInventoryStatus,
        installationError: Error? = nil,
        supportedLocales: [Locale] = [],
        equivalentLocale: Locale? = nil
    ) {
        self.statusValue = status
        self.installationError = installationError
        self.supportedLocalesValue = supportedLocales
        self.equivalentLocale = equivalentLocale
    }

    func supportedLocales() async -> [Locale] {
        supportedLocalesReadCount += 1
        return supportedLocalesValue
    }

    func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        supportedLocaleReadCount += 1
        return equivalentLocale
    }

    func status(for locale: Locale) async -> AppleSpeechAssetInventoryStatus {
        statusValue
    }

    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetInstallation? {
        requestCount += 1
        if let installationError { throw installationError }
        return AppleSpeechAssetInstallation {
            await self.finishInstallation()
        }
    }

    private func finishInstallation() {
        statusValue = .installed
    }

    func reservedLocales() async -> [Locale] {
        reservedLocalesReadCount += 1
        return [Locale(identifier: "en-US")]
    }

    func release(locale: Locale) async -> Bool {
        releaseCount += 1
        return true
    }
}

private actor FakeAppleSpeechAnalyzerBoundary: AppleSpeechAnalyzerBoundary {
    let result: String
    private(set) var samples: [Float] = []
    private(set) var invocationCount = 0

    init(result: String = "") {
        self.result = result
    }

    func transcribe(samples: [Float], locale: Locale) async throws -> String {
        invocationCount += 1
        self.samples = samples
        return result
    }

    func cancel() async {}
}

private actor BlockingAppleSpeechAnalyzerBoundary: AppleSpeechAnalyzerBoundary {
    private(set) var invocationCount = 0
    private(set) var cancelCount = 0

    func transcribe(samples: [Float], locale: Locale) async throws -> String {
        invocationCount += 1
        try await Task.sleep(for: .seconds(60))
        return "stale"
    }

    func cancel() async {
        cancelCount += 1
    }
}
