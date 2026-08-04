import Foundation
import Speech
import SwiftUI

/// Pure locale presentation rules shared by the Settings surface and tests.
enum AppleSpeechLocalePresentation {
    /// Keeps a stored user choice stable and uses the Speech framework's
    /// equivalent current locale only when no usable choice exists.
    static func initialLocaleIdentifier(
        storedIdentifier: String?,
        equivalentCurrentLocale: Locale?
    ) -> String? {
        if let storedIdentifier,
           !storedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedIdentifier
        }
        return equivalentCurrentLocale?.identifier
    }

    static func sorted(
        _ locales: [Locale],
        displayLocale: Locale = .current
    ) -> [Locale] {
        locales.sorted { lhs, rhs in
            let lhsName = displayName(for: lhs, in: displayLocale)
            let rhsName = displayName(for: rhs, in: displayLocale)
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.identifier.localizedCaseInsensitiveCompare(rhs.identifier) == .orderedAscending
        }
    }

    static func displayName(for locale: Locale, in displayLocale: Locale = .current) -> String {
        displayLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

struct TranscriptionBackendSettingsSection: View {
    let appleSpeechAssetManager: AppleSpeechAssetManager

    @EnvironmentObject private var modelManager: FluidAudioModelManager
    @AppStorage(AppDefaults.transcriptionBackend) private var backendRaw = TranscriptionBackendID.parakeetV2.rawValue
    @AppStorage(AppDefaults.appleSpeechLocale) private var appleSpeechLocaleID = ""

    @State private var supportedLocales: [Locale] = []
    @State private var appleSpeechState: AppleSpeechAssetState?
    @State private var reservedLocales: [Locale] = []
    @State private var reservedLocaleID = ""
    @State private var isCheckingLocales = false
    @State private var isAcquiring = false
    @State private var reservationError: String?

    private var selectedBackend: TranscriptionBackendID {
        TranscriptionBackendID(rawValue: backendRaw) ?? .parakeetV2
    }

    private var parakeetModel: FluidAudioModel {
        TranscriptionModelRegistry.parakeetV2
    }

    var body: some View {
        Section("Transcription Model") {
            Picker("Backend", selection: backendBinding) {
                // TranscriptionBackendID is intentionally closed and its case
                // order keeps Parakeet V2 first/default in the picker.
                ForEach(TranscriptionBackendID.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }

            switch selectedBackend {
            case .parakeetV2:
                parakeetDetails
            case .appleSpeech:
                appleSpeechDetails
            }
        }
        .task {
            await loadSupportedLocales()
        }
        .onAppear {
            repairInvalidBackend()
        }
        .onChange(of: backendRaw) { _, newValue in
            guard TranscriptionBackendID(rawValue: newValue) == .appleSpeech else {
                appleSpeechState = nil
                return
            }
            refreshSelectedLocale()
        }
        .onChange(of: appleSpeechLocaleID) { _, _ in
            guard selectedBackend == .appleSpeech else { return }
            refreshSelectedLocale()
        }
    }

    private var backendBinding: Binding<TranscriptionBackendID> {
        Binding(
            get: { selectedBackend },
            set: { backendRaw = $0.rawValue }
        )
    }

    @ViewBuilder
    private var parakeetDetails: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(parakeetModel.displayName)
                Text("Default on-device transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if modelManager.isFluidAudioModelDownloaded(parakeetModel) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if modelManager.isFluidAudioModelDownloading(parakeetModel) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Download") {
                    Task {
                        await modelManager.downloadFluidAudioModel(parakeetModel)
                    }
                }
            }
        }

        if let status = modelManager.downloadStatus(for: parakeetModel) {
            VStack(alignment: .leading, spacing: 4) {
                if status.isIndeterminate {
                    ProgressView()
                } else {
                    ProgressView(value: status.fractionCompleted)
                }
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let error = modelManager.lastDownloadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var appleSpeechDetails: some View {
        Text("On-device transcription managed by macOS")
            .font(.caption)
            .foregroundStyle(.secondary)

        if isCheckingLocales {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Checking supported languages…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Language", selection: $appleSpeechLocaleID) {
                Text("Choose a language")
                    .tag("")
                ForEach(localeOptions, id: \.identifier) { locale in
                    Text(AppleSpeechLocalePresentation.displayName(for: locale))
                        .tag(locale.identifier)
                }
            }

            if let locale = selectedLocale {
                appleSpeechAssetStatus(for: locale)
            } else {
                Label(
                    "Choose an Apple Speech language before recording.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var localeOptions: [Locale] {
        var locales = supportedLocales
        if let selectedLocale,
           !locales.contains(where: { $0.identifier == selectedLocale.identifier }) {
            locales.append(selectedLocale)
        }
        return AppleSpeechLocalePresentation.sorted(locales)
    }

    private var selectedLocale: Locale? {
        guard !appleSpeechLocaleID.isEmpty else { return nil }
        return Locale(identifier: appleSpeechLocaleID)
    }

    @ViewBuilder
    private func appleSpeechAssetStatus(for locale: Locale) -> some View {
        let presentation = AppleSpeechAssetPresentation.forState(appleSpeechState)

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(statusTitle(for: presentation.status), systemImage: statusIcon(for: presentation.status))
                    .foregroundStyle(statusColor(for: presentation.status))
                Spacer()
                if presentation.action == .download {
                    Button("Download") {
                        acquire(locale: locale)
                    }
                    .disabled(isAcquiring)
                }
            }

            Text(statusDetail(for: appleSpeechState))
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .downloading(let progress) = appleSpeechState {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }

            if case .failed(let message) = appleSpeechState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if presentation.status == .reservationLimit {
                reservationControls
            }
        }
    }

    @ViewBuilder
    private var reservationControls: some View {
        if reservedLocales.isEmpty {
            Text("No reserved locales were reported by the system.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Reserved language", selection: $reservedLocaleID) {
                ForEach(reservedLocales, id: \.identifier) { locale in
                    Text(AppleSpeechLocalePresentation.displayName(for: locale))
                        .tag(locale.identifier)
                }
            }

            Button("Release reservation") {
                releaseSelectedReservation()
            }
            .disabled(reservedLocaleID.isEmpty)

            Text("The operating system may retain shared assets after release.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reservationError {
                Text(reservationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func repairInvalidBackend() {
        guard TranscriptionBackendID(rawValue: backendRaw) == nil else { return }
        backendRaw = TranscriptionBackendID.parakeetV2.rawValue
    }

    private func loadSupportedLocales() async {
        guard supportedLocales.isEmpty else {
            if selectedBackend == .appleSpeech { refreshSelectedLocale() }
            return
        }

        isCheckingLocales = true
        let discovered = await appleSpeechAssetManager.supportedLocales()
        supportedLocales = AppleSpeechLocalePresentation.sorted(discovered)

        if appleSpeechLocaleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let equivalent = await appleSpeechAssetManager.supportedLocale(equivalentTo: .current)
            if let initialIdentifier = AppleSpeechLocalePresentation.initialLocaleIdentifier(
                storedIdentifier: appleSpeechLocaleID,
                equivalentCurrentLocale: equivalent
            ) {
                appleSpeechLocaleID = initialIdentifier
            }
        }

        isCheckingLocales = false
        if selectedBackend == .appleSpeech {
            refreshSelectedLocale()
        }
    }

    private func refreshSelectedLocale() {
        guard let locale = selectedLocale else {
            appleSpeechState = nil
            reservedLocales = []
            reservedLocaleID = ""
            return
        }

        appleSpeechState = nil
        Task {
            let state = await appleSpeechAssetManager.refresh(for: locale)
            guard selectedBackend == .appleSpeech, appleSpeechLocaleID == locale.identifier else { return }
            appleSpeechState = state
            if state == .reservationLimit {
                await refreshReservations(for: locale.identifier)
            } else {
                reservedLocales = []
                reservedLocaleID = ""
            }
        }
    }

    private func acquire(locale: Locale) {
        guard !isAcquiring else { return }
        isAcquiring = true
        appleSpeechState = .downloading(progress: nil)

        Task {
            defer { isAcquiring = false }
            do {
                let state = try await appleSpeechAssetManager.requestInstallation(for: locale)
                guard selectedBackend == .appleSpeech, appleSpeechLocaleID == locale.identifier else { return }
                appleSpeechState = state
                if state == .reservationLimit {
                    await refreshReservations(for: locale.identifier)
                }
            } catch {
                guard selectedBackend == .appleSpeech, appleSpeechLocaleID == locale.identifier else { return }
                appleSpeechState = await appleSpeechAssetManager.state(for: locale)
                    ?? .failed(message: error.localizedDescription)
                if case .reservationLimit? = appleSpeechState {
                    await refreshReservations(for: locale.identifier)
                }
            }
        }
    }

    private func refreshReservations(for localeIdentifier: String) async {
        let locales = AppleSpeechLocalePresentation.sorted(
            await appleSpeechAssetManager.reservedLocales()
        )
        guard selectedBackend == .appleSpeech,
              appleSpeechLocaleID == localeIdentifier else { return }
        reservedLocales = locales
        if !locales.contains(where: { $0.identifier == reservedLocaleID }) {
            reservedLocaleID = locales.first?.identifier ?? ""
        }
    }

    private func releaseSelectedReservation() {
        guard let locale = reservedLocales.first(where: { $0.identifier == reservedLocaleID }) else { return }
        reservationError = nil
        let selectedLocaleIdentifierAtStart = appleSpeechLocaleID

        Task {
            let released = await appleSpeechAssetManager.release(locale: locale)
            guard selectedBackend == .appleSpeech,
                  appleSpeechLocaleID == selectedLocaleIdentifierAtStart else { return }
            guard released else {
                reservationError = "The reservation could not be released."
                return
            }
            await refreshReservations(for: selectedLocaleIdentifierAtStart)
            let selectedLocale = Locale(identifier: selectedLocaleIdentifierAtStart)
            let state = await appleSpeechAssetManager.refresh(for: selectedLocale)
            guard selectedBackend == .appleSpeech,
                  appleSpeechLocaleID == selectedLocaleIdentifierAtStart else { return }
            appleSpeechState = state
        }
    }

    private func statusTitle(for status: AppleSpeechAssetPresentationStatus) -> String {
        switch status {
        case .checking: return "Checking"
        case .downloadRequired: return "Download required"
        case .downloading: return "Downloading"
        case .ready: return "Ready"
        case .unsupported: return "Unsupported"
        case .reservationLimit: return "Reservation limit"
        case .failed: return "Failed"
        }
    }

    private func statusIcon(for status: AppleSpeechAssetPresentationStatus) -> String {
        switch status {
        case .checking: return "hourglass"
        case .downloadRequired: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle"
        case .ready: return "checkmark.circle.fill"
        case .unsupported: return "xmark.circle"
        case .reservationLimit: return "externaldrive.badge.exclamationmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func statusColor(for status: AppleSpeechAssetPresentationStatus) -> Color {
        switch status {
        case .ready: return .green
        case .unsupported, .failed, .reservationLimit: return .red
        default: return .secondary
        }
    }

    private func statusDetail(for state: AppleSpeechAssetState?) -> String {
        switch state {
        case nil, .requested:
            return "Checking Apple Speech availability."
        case .unsupported:
            return "Choose another supported language before recording."
        case .absent:
            return "Download this language before recording."
        case .reclaimed:
            return "The operating system reclaimed these assets. Download them again before recording."
        case .downloading:
            return "Wait for the language download to finish before recording."
        case .ready:
            return "This language is ready for the next recording."
        case .reservationLimit:
            return "Release an unused reservation below, then download this language."
        case .failed:
            return "The download failed. Try again, or choose another language."
        }
    }
}
