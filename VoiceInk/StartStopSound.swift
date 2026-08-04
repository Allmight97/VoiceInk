import AppKit

enum StartStopSound {
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppDefaults.soundFeedbackEnabled) as? Bool ?? true
    }

    static func playStart() {
        play(named: "Tink")
    }

    static func playStop() {
        play(named: "Pop")
    }

    static func playError() {
        play(named: "Basso")
    }

    private static func play(named name: String) {
        guard isEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
