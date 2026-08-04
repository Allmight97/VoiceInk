import Foundation

enum AppMetadata {
    static let changelogURL = URL(string: "https://github.com/Allmight97/VoiceInk/blob/main/CHANGELOG.md")!

    static var versionDisplay: String {
        versionDisplay(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func versionDisplay(shortVersion: String?, build: String?) -> String {
        "\(shortVersion ?? "Unknown") (\(build ?? "Unknown"))"
    }
}
