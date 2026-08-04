import AVFoundation
import CoreMedia
import Foundation
import Speech

struct AppleSpeechTranscriptSegment: Equatable, Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
    let isFinal: Bool

    init(startTime: Double, endTime: Double, text: String, isFinal: Bool) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
    }
}

/// Keeps only final text and lets a final result replace a prior result for the
/// same time range. Volatile updates never leak into the returned transcript.
struct AppleSpeechTranscriptAccumulator: Sendable {
    private struct Key: Hashable, Sendable {
        let startTime: Double
        let endTime: Double
    }

    private struct Entry: Sendable {
        let segment: AppleSpeechTranscriptSegment
        let sequence: Int
    }

    private var entries: [Key: Entry] = [:]
    private var sequence = 0

    mutating func append(_ segment: AppleSpeechTranscriptSegment) {
        let key = Key(startTime: segment.startTime, endTime: segment.endTime)
        if let existing = entries[key], existing.segment.isFinal, !segment.isFinal {
            return
        }

        sequence += 1
        entries[key] = Entry(segment: segment, sequence: sequence)
    }

    var finalSegments: [AppleSpeechTranscriptSegment] {
        entries.values
            .filter(\.segment.isFinal)
            .sorted {
                if $0.segment.startTime != $1.segment.startTime {
                    return $0.segment.startTime < $1.segment.startTime
                }
                if $0.segment.endTime != $1.segment.endTime {
                    return $0.segment.endTime < $1.segment.endTime
                }
                return $0.sequence < $1.sequence
            }
            .map(\.segment)
    }

    var finalText: String {
        finalSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol AppleSpeechAnalyzerBoundary: Sendable {
    func transcribe(samples: [Float], locale: Locale) async throws -> [AppleSpeechTranscriptSegment]
    func cancel() async
}

actor SystemAppleSpeechAnalyzerBoundary: AppleSpeechAnalyzerBoundary {
    private let sampleRate: Double = 16_000
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<[AppleSpeechTranscriptSegment], Error>?
    private var operationID: UUID?

    func transcribe(samples: [Float], locale: Locale) async throws -> [AppleSpeechTranscriptSegment] {
        await cancel()
        try Task.checkCancellation()

        let operationID = UUID()
        self.operationID = operationID
        defer {
            if self.operationID == operationID {
                self.analyzer = nil
                self.resultsTask = nil
                self.operationID = nil
            }
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )
        let modules: [any SpeechModule] = [transcriber]
        let sourceFormat = try makeSourceFormat()
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules,
            considering: sourceFormat
        ) ?? sourceFormat
        let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let resultsTask = Task { [transcriber] in
            var segments: [AppleSpeechTranscriptSegment] = []
            for try await result in transcriber.results {
                let range = result.range
                let start = range.start.seconds
                let end = range.end.seconds
                segments.append(AppleSpeechTranscriptSegment(
                    startTime: start.isFinite ? start : 0,
                    endTime: end.isFinite ? end : start,
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                ))
            }
            return segments
        }
        self.resultsTask = resultsTask

        return try await withTaskCancellationHandler {
            do {
                // `start` returns after the analyzer owns the sequence.
                // Starting before yielding or finalizing removes a race where
                // the sequence could be finalized before the analyzer saw it.
                try await analyzer.start(inputSequence: inputSequence)
                let buffer = try makeBuffer(samples: samples, format: sourceFormat)
                for input in try converter.convert(buffer, at: nil) {
                    continuation.yield(input)
                }
                for input in try converter.flush() {
                    continuation.yield(input)
                }
                continuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await resultsTask.value
            } catch {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                resultsTask.cancel()
                throw error
            }
        } onCancel: {
            continuation.finish()
            resultsTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func cancel() async {
        operationID = nil
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resultsTask = nil
    }

    private func makeSourceFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppleSpeechTranscriptionError.audioFormatUnavailable
        }
        return format
    }

    private func makeBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?.pointee else {
            throw AppleSpeechTranscriptionError.audioBufferUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        return buffer
    }
}
