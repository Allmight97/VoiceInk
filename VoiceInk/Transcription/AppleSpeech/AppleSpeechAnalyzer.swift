import AVFoundation
import Foundation
import Speech

/// Keeps finalized results in the order emitted by SpeechTranscriber.
struct AppleSpeechTranscriptAccumulator: Sendable {
    private var finalized: [String] = []

    mutating func append(text: String, isFinal: Bool) {
        guard isFinal else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        finalized.append(text)
    }

    var finalText: String {
        finalized
            .joined(separator: " ")
    }
}

protocol AppleSpeechAnalyzerBoundary: Sendable {
    func transcribe(samples: [Float], locale: Locale) async throws -> String
    func cancel() async
}

actor SystemAppleSpeechAnalyzerBoundary: AppleSpeechAnalyzerBoundary {
    private let sampleRate: Double = 16_000
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<String, Error>?
    private var operationID: UUID?

    func transcribe(samples: [Float], locale: Locale) async throws -> String {
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
            var transcript = AppleSpeechTranscriptAccumulator()
            for try await result in transcriber.results {
                transcript.append(
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                )
            }
            return transcript.finalText
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
