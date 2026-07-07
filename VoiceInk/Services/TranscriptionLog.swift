import Foundation
import os

/// Minimal append-only dictation history: one JSON object per line at
/// Application Support/com.prakashjoshipax.VoiceInk/transcriptions.jsonl.
/// No database, greppable, inert at idle. Gated by EnableHistoryLog.
enum TranscriptionLog {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionLog")
    private static let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.transcriptionlog", qos: .utility)

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("transcriptions.jsonl")
    }

    static func append(text: String) {
        guard UserDefaults.standard.bool(forKey: AppDefaults.enableHistoryLog) else { return }

        queue.async {
            do {
                let entry: [String: String] = [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "text": text
                ]
                var line = try JSONSerialization.data(withJSONObject: entry)
                line.append(0x0A)

                let url = fileURL
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try line.write(to: url)
                    return
                }

                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                logger.error("Could not append to history log: \(error, privacy: .public)")
            }
        }
    }

    static func lastText() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n").reversed() {
            if let lineData = line.data(using: .utf8),
               let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: String],
               let text = entry["text"], !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
