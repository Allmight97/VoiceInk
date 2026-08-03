import FluidAudio

actor FluidAudioTranscriptionService {
    private var asrManager: AsrManager?
    private var activeVersion: AsrModelVersion?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
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

    func loadModel() async throws {
        try await ensureModelsLoaded(for: .v2)
    }

    func transcribe(samples: [Float]) async throws -> String {
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
}
