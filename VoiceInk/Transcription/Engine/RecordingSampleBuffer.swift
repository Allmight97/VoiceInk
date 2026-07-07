import Foundation
import os

/// Shared signposter for profiling the dictation hot path in Instruments.
enum LeanSignpost {
    static let signposter = OSSignposter(
        subsystem: "com.prakashjoshipax.VoiceInk",
        category: "leanpath"
    )
}

/// Thread-safe accumulator for the recorder's converted 16 kHz mono PCM16
/// chunks, so transcription reads from memory instead of re-reading the WAV.
final class RecordingSampleBuffer: @unchecked Sendable {
    /// 30 minutes of 16 kHz mono PCM16.
    private static let maxBytes = 16_000 * 2 * 60 * 30

    private let lock = NSLock()
    private var data: Data
    private var didReportOverflow = false

    /// True once the 30-minute cap was hit; further chunks are dropped.
    private(set) var overflowed = false

    init() {
        // Reserve ~5 minutes up front to avoid repeated growth copies.
        data = Data(capacity: 16_000 * 2 * 60 * 5)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count + chunk.count <= Self.maxBytes else {
            overflowed = true
            return
        }
        data.append(chunk)
    }

    /// Non-consuming copy of the samples accumulated so far (live-transcript
    /// partial passes read this while recording continues).
    func snapshotFloatSamples() -> [Float] {
        lock.lock()
        let bytes = data
        lock.unlock()

        return bytes.withUnsafeBytes { raw -> [Float] in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            return int16Buffer.map { sample in
                max(-1.0, min(Float(Int16(littleEndian: sample)) / 32767.0, 1.0))
            }
        }
    }

    /// Converts the accumulated PCM16 bytes to normalized Float samples and
    /// releases the byte storage.
    func takeFloatSamples() -> [Float] {
        lock.lock()
        let bytes = data
        data = Data()
        lock.unlock()

        return bytes.withUnsafeBytes { raw -> [Float] in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            return int16Buffer.map { sample in
                max(-1.0, min(Float(Int16(littleEndian: sample)) / 32767.0, 1.0))
            }
        }
    }

    func discard() {
        lock.lock()
        data = Data()
        lock.unlock()
    }
}

/// Minimal 16 kHz mono PCM16 WAV encoder, used only as a compatibility bridge
/// for engines that require file input (and for DebugKeepRecordings).
enum WAVEncoder {
    /// Reads 16 kHz mono PCM16 WAV bytes back into normalized Float samples
    /// (fallback path when the in-memory buffer is unavailable).
    static func readSamples(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        return stride(from: 44, to: data.count - 1, by: 2).map { offset in
            data[offset..<offset + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
    }

    static func write(samples: [Float], to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-32768, min(32767, sample * 32767))).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        let sampleRate: UInt32 = 16_000
        let byteRate = sampleRate * 2
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(uint32: UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(uint32: 16)
        header.append(uint16: 1)          // PCM
        header.append(uint16: 1)          // mono
        header.append(uint32: sampleRate)
        header.append(uint32: byteRate)
        header.append(uint16: 2)          // block align
        header.append(uint16: 16)         // bits per sample
        header.append(contentsOf: Array("data".utf8))
        header.append(uint32: UInt32(pcm.count))

        try (header + pcm).write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
