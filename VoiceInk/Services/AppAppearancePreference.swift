import AppKit
import Foundation

enum AppAppearancePreference: String, CaseIterable, Hashable, Identifiable {
    static let userDefaultsKey = "AppAppearancePreference"

    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "System")
        case .light:
            return String(localized: "Light")
        case .dark:
            return String(localized: "Dark")
        }
    }

    static var stored: AppAppearancePreference {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? Self.system.rawValue
        return AppAppearancePreference(rawValue: rawValue) ?? .system
    }

    @MainActor
    static func applyStored() {
        stored.apply()
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = appKitAppearance
    }

    @MainActor
    private var appKitAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
