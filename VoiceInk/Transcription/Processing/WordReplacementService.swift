import Foundation

@MainActor
final class WordReplacementService {
    static let shared = WordReplacementService()

    private init() {}

    func applyReplacements(to text: String) -> String {
        guard UserDefaults.standard.bool(forKey: AppDefaults.wordReplacementEnabled),
              let replacements = UserDefaults.standard.dictionary(forKey: AppDefaults.wordReplacements) as? [String: String],
              !replacements.isEmpty else {
            return text
        }

        var modifiedText = text

        let sortedReplacements = replacements.sorted {
            $0.key.count > $1.key.count
        }

        for (originalGroup, replacementText) in sortedReplacements {
            let variants = originalGroup
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.count > $1.count }

            for original in variants {
                if usesWordBoundaries(for: original) {
                    let escaped = NSRegularExpression.escapedPattern(for: original)
                    let pattern = "(?<![a-zA-Z0-9])\(escaped)(?![a-zA-Z0-9])"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(modifiedText.startIndex..., in: modifiedText)
                        modifiedText = regex.stringByReplacingMatches(
                            in: modifiedText,
                            options: [],
                            range: range,
                            withTemplate: replacementText
                        )
                    }
                } else {
                    modifiedText = modifiedText.replacingOccurrences(
                        of: original,
                        with: replacementText,
                        options: .caseInsensitive
                    )
                }
            }
        }

        return modifiedText
    }

    private func usesWordBoundaries(for text: String) -> Bool {
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F,
            0x30A0...0x30FF,
            0x4E00...0x9FFF,
            0xAC00...0xD7AF,
            0x0E00...0x0E7F,
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts where range.contains(scalar.value) {
                return false
            }
        }

        return true
    }
}
