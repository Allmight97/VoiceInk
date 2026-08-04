import Foundation

extension UserDefaults {
    enum Keys {
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let selectedAudioDeviceModelUID = "selectedAudioDeviceModelUID"
    }

    var audioInputModeRawValue: String? {
        get { string(forKey: Keys.audioInputMode) }
        set { setValue(newValue, forKey: Keys.audioInputMode) }
    }

    var selectedAudioDeviceUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceUID) }
    }

    var selectedAudioDeviceModelUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceModelUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceModelUID) }
    }

}
