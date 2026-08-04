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
        #expect(AppleSpeechAssetStateMachine.observed(status: .downloading, previous: .absent) == .downloading(progress: nil))
    }

    @Test("Asset request transitions are explicit and progress is optional")
    func assetRequestTransitions() {
        #expect(AppleSpeechAssetStateMachine.requested() == .requested)
        #expect(AppleSpeechAssetStateMachine.downloading(progress: nil) == .downloading(progress: nil))
        #expect(AppleSpeechAssetStateMachine.downloading(progress: 0.5) == .downloading(progress: 0.5))
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

    @Test("Prepare and transcribe never request absent assets")
    func noImplicitAssetAcquisition() async throws {
        let boundary = FakeAppleSpeechAssetBoundary(status: .installed)
        let analyzer = FakeAppleSpeechAnalyzerBoundary(segments: [
            AppleSpeechTranscriptSegment(startTime: 0, endTime: 1, text: "hello", isFinal: true)
        ])
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

    @Test("Volatile results are replaced by final results and ordered by time")
    func finalTailAggregation() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.append(AppleSpeechTranscriptSegment(startTime: 2, endTime: 3, text: "world", isFinal: false))
        accumulator.append(AppleSpeechTranscriptSegment(startTime: 0, endTime: 1, text: "hello", isFinal: true))
        accumulator.append(AppleSpeechTranscriptSegment(startTime: 2, endTime: 3, text: "world!", isFinal: true))
        accumulator.append(AppleSpeechTranscriptSegment(startTime: 0, endTime: 1, text: "stale", isFinal: false))

        #expect(accumulator.finalText == "hello world!")
        #expect(accumulator.finalSegments.map(\.text) == ["hello", "world!"])
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
    private(set) var requestCount = 0
    private(set) var reservedLocalesReadCount = 0
    private(set) var releaseCount = 0

    init(status: AppleSpeechAssetInventoryStatus, installationError: Error? = nil) {
        self.statusValue = status
        self.installationError = installationError
    }

    func status(for locale: Locale) async -> AppleSpeechAssetInventoryStatus {
        statusValue
    }

    func requestInstallation(for locale: Locale) async throws -> AppleSpeechAssetInstallation? {
        requestCount += 1
        if let installationError { throw installationError }
        return AppleSpeechAssetInstallation(
            progress: { nil },
            downloadAndInstall: { await self.finishInstallation() }
        )
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
    let segments: [AppleSpeechTranscriptSegment]
    private(set) var samples: [Float] = []
    private(set) var invocationCount = 0

    init(segments: [AppleSpeechTranscriptSegment] = []) {
        self.segments = segments
    }

    func transcribe(samples: [Float], locale: Locale) async throws -> [AppleSpeechTranscriptSegment] {
        invocationCount += 1
        self.samples = samples
        return segments
    }

    func cancel() async {}
}

private actor BlockingAppleSpeechAnalyzerBoundary: AppleSpeechAnalyzerBoundary {
    private(set) var invocationCount = 0
    private(set) var cancelCount = 0

    func transcribe(samples: [Float], locale: Locale) async throws -> [AppleSpeechTranscriptSegment] {
        invocationCount += 1
        try await Task.sleep(for: .seconds(60))
        return [AppleSpeechTranscriptSegment(startTime: 0, endTime: 1, text: "stale", isFinal: true)]
    }

    func cancel() async {
        cancelCount += 1
    }
}
