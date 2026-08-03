import FluidAudio
import Foundation
import os

actor FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var activeVersion: AsrModelVersion?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")

    var isModelLoaded: Bool {
        asrManager != nil && activeVersion == .v2
    }

    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            try await AsrModels.downloadAndLoad(
                configuration: nil,
                version: version
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            cachedModels = models
            if loadingTask?.version == version {
                loadingTask = nil
            }
            return models
        } catch {
            if loadingTask?.version == version {
                loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        try await ensureModelsLoaded(for: .v2)
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        try await transcribe(samples: readAudioSamples(from: audioURL), model: model, context: context)
    }

    func transcribe(samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        try await ensureModelsLoaded(for: .v2)

        guard let asrManager else {
            throw ASRError.notInitialized
        }

        var speechAudio = samples
        let trailingSilenceSamples = 16_000
        let maxSingleChunkSamples = 240_000
        if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
            speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(
            speechAudio,
            decoderState: &decoderState,
            language: nil
        )

        return TextNormalizer.shared.normalizeSentence(result.text)
    }

    func cleanup() async {
        await asrManager?.cleanup()
        asrManager = nil
        activeVersion = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        await cleanup()

        let models = try await getOrLoadModels(for: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
        activeVersion = version
    }

    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else {
                throw ASRError.invalidAudioData
            }

            return stride(from: 44, to: data.count, by: 2).map {
                data[$0..<$0 + 2].withUnsafeBytes {
                    let short = Int16(littleEndian: $0.load(as: Int16.self))
                    return max(-1.0, min(Float(short) / 32767.0, 1.0))
                }
            }
        } catch {
            logger.error("Could not read audio samples: \(error, privacy: .public)")
            throw ASRError.invalidAudioData
        }
    }
}
