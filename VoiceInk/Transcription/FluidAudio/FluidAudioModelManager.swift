import AppKit
import FluidAudio
import Foundation
import os

struct FluidAudioDownloadStatus {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool

    init(fractionCompleted: Double, message: String, isIndeterminate: Bool = false) {
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.isIndeterminate = isIndeterminate
    }
}

@MainActor
final class FluidAudioModelManager: ObservableObject {
    @Published private var downloadStatuses: [String: FluidAudioDownloadStatus] = [:]
    @Published private var modelStateRevision = 0
    private var activeDownloadIDs: [String: UUID] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioModelManager")
    private static let parakeetV2Name = "parakeet-tdt-0.6b-v2"

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        .v2
    }

    init() {}

    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        AsrModels.modelsExist(at: cacheDirectory(for: .v2), version: .v2)
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        downloadStatuses[model.name] != nil
    }

    func downloadStatus(for model: FluidAudioModel) -> FluidAudioDownloadStatus? {
        downloadStatuses[model.name]
    }

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        guard model.name == Self.parakeetV2Name else { return }
        if isFluidAudioModelDownloaded(model) || isFluidAudioModelDownloading(model) {
            return
        }

        let modelName = model.name
        let downloadID = UUID()
        activeDownloadIDs[modelName] = downloadID
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: 0.0,
            message: "Preparing FluidAudio download..."
        )
        defer {
            clearDownloadStatus(for: modelName, downloadID: downloadID)
            onModelsChanged?()
        }

        let progressHandler: DownloadUtils.ProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress(progress, for: modelName, downloadID: downloadID)
            }
        }

        do {
            _ = try await AsrModels.downloadAndLoad(
                version: .v2,
                progressHandler: progressHandler
            )
            modelStateRevision += 1
        } catch {
            logger.error("FluidAudio download failed for \(modelName, privacy: .public): \(error, privacy: .public)")
        }
    }

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            logger.error("FluidAudio model delete failed: \(error, privacy: .public)")
        }

        modelStateRevision += 1
        onModelDeleted?(model.name)
    }

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let directory = cacheDirectory(for: model)
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.selectFile(directory.path, inFileViewerRootedAtPath: "")
        }
    }

    private func cacheDirectory(for model: FluidAudioModel) -> URL {
        cacheDirectory(for: Self.asrVersion(for: model.name))
    }

    private func cacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    private func clearDownloadStatus(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeDownloadIDs[modelName] = nil
        downloadStatuses[modelName] = nil
    }

    private func updateDownloadProgress(_ progress: DownloadUtils.DownloadProgress, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }

        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: min(max(progress.fractionCompleted, 0.0), 1.0),
            message: Self.statusMessage(for: progress),
            isIndeterminate: Self.isIndeterminatePhase(progress.phase)
        )
    }

    private static func isIndeterminatePhase(_ phase: DownloadUtils.DownloadPhase) -> Bool {
        if case .compiling(let modelName) = phase {
            return modelName.isEmpty
        }
        return false
    }

    private static func statusMessage(for progress: DownloadUtils.DownloadProgress) -> String {
        switch progress.phase {
        case .listing:
            return String(localized: "Listing files from repository...")
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else {
                return String(localized: "Checking cached models...")
            }
            return String(format: String(localized: "Downloading model files: %lld/%lld"), Int64(completedFiles), Int64(totalFiles))
        case .compiling(let modelName):
            guard !modelName.isEmpty else {
                return String(localized: "Finalizing models...")
            }
            return String(format: String(localized: "Compiling %@"), displayName(forModelComponent: modelName))
        }
    }

    private static func displayName(forModelComponent modelName: String) -> String {
        modelName.replacingOccurrences(of: ".mlmodelc", with: "")
    }
}
