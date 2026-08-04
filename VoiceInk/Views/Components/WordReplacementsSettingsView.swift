import SwiftUI

struct WordReplacementsSettingsSection: View {
    @AppStorage(AppDefaults.wordReplacementEnabled) private var isEnabled = false
    @State private var replacements: [String: String] = Self.loadReplacements()
    @State private var newOriginal = ""
    @State private var newReplacement = ""

    var body: some View {
        Section {
            Toggle("Apply Word Replacements", isOn: $isEnabled)
        } footer: {
            Text("Replaces matches in the final transcription before pasting. Separate variants with commas (e.g. \"calbree, calibri\" → \"Calibre\").")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Replacements") {
            if replacements.isEmpty {
                Text("No replacements yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(replacements.sorted(by: { $0.key < $1.key }), id: \.key) { original, replacement in
                    HStack {
                        Text(original)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(replacement)
                        Spacer()
                        Button {
                            replacements.removeValue(forKey: original)
                            persist()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            HStack {
                TextField("Original", text: $newOriginal)
                TextField("Replacement", text: $newReplacement)
                Button("Add") { addReplacement() }
                    .disabled(trimmedOriginal.isEmpty || trimmedReplacement.isEmpty)
            }
        }
    }

    private var trimmedOriginal: String {
        newOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addReplacement() {
        guard !trimmedOriginal.isEmpty, !trimmedReplacement.isEmpty else { return }
        replacements[trimmedOriginal] = trimmedReplacement
        newOriginal = ""
        newReplacement = ""
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(replacements, forKey: AppDefaults.wordReplacements)
    }

    private static func loadReplacements() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: AppDefaults.wordReplacements) as? [String: String] ?? [:]
    }
}
