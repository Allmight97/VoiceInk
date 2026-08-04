import Foundation
import CoreAudio
import os

enum AudioInputMode: String, CaseIterable {
    case systemDefault = "System Default"
    case custom = "Custom Device"
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioDeviceManager")
    @Published var availableDevices: [(id: AudioDeviceID, uid: String, name: String)] = []
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var inputMode: AudioInputMode = .custom

    var isRecordingActive: Bool = false

    static let shared = AudioDeviceManager()

    init() {
        if let savedMode = UserDefaults.standard.audioInputModeRawValue,
           let mode = AudioInputMode(rawValue: savedMode) {
            inputMode = mode
        } else {
            inputMode = .systemDefault
        }

        loadAvailableDevices { [weak self] in
            self?.initializeSelectedDevice()
        }

        setupDeviceChangeNotifications()
    }

    func getSystemDefaultDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr,
              CoreAudioByteContract.hasExactSize(
                  propertySize,
                  expectedBytes: MemoryLayout<AudioDeviceID>.size
              ),
              deviceID != 0 else {
            logger.error("Failed to get system default device: \(status, privacy: .public)")
            return nil
        }
        return deviceID
    }

    private func initializeSelectedDevice() {
        switch inputMode {
        case .systemDefault:
            break
        case .custom:
            if let savedUID = UserDefaults.standard.selectedAudioDeviceUID {
                let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID
                if let found = findAvailableDevice(uid: savedUID, modelUID: savedModelUID) {
                    selectedDeviceID = found.id
                    if found.uid != savedUID || savedModelUID == nil {
                        updateCustomDeviceHints(deviceID: found.id, uid: found.uid)
                    }
                } else {
                    fallbackToDefaultDevice()
                }
            } else {
                fallbackToDefaultDevice()
            }
        }
    }
    
    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        return availableDevices.contains { $0.id == deviceID }
    }
    
    private func fallbackToDefaultDevice() {
        guard let newDeviceID = findBestAvailableDevice() else {
            logger.error("No input devices available!")
            selectedDeviceID = nil
            notifyDeviceChange()
            return
        }
        activateDevice(id: newDeviceID)
    }

    private func activateDevice(id: AudioDeviceID) {
        selectedDeviceID = id
        notifyDeviceChange()
    }

    func findBestAvailableDevice() -> AudioDeviceID? {
        if let device = availableDevices.first(where: { isBuiltInDevice($0.id) }) {
            return device.id
        }
        return availableDevices.first?.id
    }

    private func isBuiltInDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = getDeviceUID(deviceID: deviceID) else {
            return false
        }
        return uid.contains("BuiltIn")
    }
    
    func loadAvailableDevices(completion: (() -> Void)? = nil) {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        guard result == noErr,
              let deviceCount = CoreAudioByteContract.elementCount(
                  returnedBytes: propertySize,
                  elementStride: MemoryLayout<AudioDeviceID>.stride
              ) else {
            logger.error("Invalid audio device list size: status=\(result, privacy: .public), bytes=\(propertySize, privacy: .public)")
            return
        }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        if deviceCount > 0 {
            var returnedBytes = propertySize
            let dataStatus: OSStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return kAudio_ParamError
                }
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &returnedBytes,
                    baseAddress
                )
            }

            guard dataStatus == noErr,
                  let returnedDeviceCount = CoreAudioByteContract.elementCount(
                      returnedBytes: returnedBytes,
                      elementStride: MemoryLayout<AudioDeviceID>.stride
                  ),
                  returnedDeviceCount <= deviceCount else {
                logger.error("Invalid audio device list response: status=\(dataStatus, privacy: .public), bytes=\(returnedBytes, privacy: .public)")
                return
            }
            deviceIDs.removeLast(deviceCount - returnedDeviceCount)
        }

        let devices = deviceIDs.compactMap { deviceID -> (id: AudioDeviceID, uid: String, name: String)? in
            guard let name = getDeviceName(deviceID: deviceID),
                  let uid = getDeviceUID(deviceID: deviceID),
                  isValidInputDevice(deviceID: deviceID) else {
                return nil
            }
            return (id: deviceID, uid: uid, name: name)
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.availableDevices = devices.map { ($0.id, $0.uid, $0.name) }
            if let currentID = self.selectedDeviceID, !devices.contains(where: { $0.id == currentID }) {
                if !self.isRecordingActive {
                    self.fallbackToDefaultDevice()
                }
            }
            completion?()
        }
    }
    
    func getDeviceName(deviceID: AudioDeviceID) -> String? {
        getDeviceStringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString
        )
    }
    
    private func isValidInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        )

        if result != noErr {
            logger.error("Error checking input capability for device \(deviceID, privacy: .public): \(result, privacy: .public)")
            return false
        }

        let storageSize = Int(propertySize)
        guard storageSize >= MemoryLayout<AudioBufferList>.size else {
            logger.error("Audio stream configuration is smaller than an AudioBufferList header")
            return false
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        var returnedBytes = propertySize
        result = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &returnedBytes,
            storage
        )

        guard result == noErr,
              returnedBytes <= propertySize,
              returnedBytes >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            logger.error("Error getting stream configuration for device \(deviceID, privacy: .public): \(result, privacy: .public)")
            return false
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        guard let requiredBytes = CoreAudioByteContract.variableStructByteCount(
            elementCount: bufferCount,
            minimumHeaderBytes: MemoryLayout<AudioBufferList>.size,
            elementStride: MemoryLayout<AudioBuffer>.stride
        ),
        requiredBytes <= Int(returnedBytes) else {
            return false
        }
        return bufferCount > 0
    }

    func selectDevice(id: AudioDeviceID) {
        if let deviceToSelect = availableDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.selectedDeviceID = id
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectDeviceAndSwitchToCustomMode(id: AudioDeviceID) {
        if let deviceToSelect = availableDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.inputMode = .custom
                self.selectedDeviceID = id
                UserDefaults.standard.audioInputModeRawValue = AudioInputMode.custom.rawValue
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectInputMode(_ mode: AudioInputMode) {
        inputMode = mode
        UserDefaults.standard.audioInputModeRawValue = mode.rawValue

        switch mode {
        case .systemDefault:
            break
        case .custom:
            if selectedDeviceID == nil {
                if let firstDevice = availableDevices.first {
                    selectDevice(id: firstDevice.id)
                }
            }
        }

        notifyDeviceChange()
    }
    
    func getCurrentDevice() -> AudioDeviceID {
        switch inputMode {
        case .systemDefault:
            return getSystemDefaultDevice() ?? findBestAvailableDevice() ?? 0
        case .custom:
            if let id = selectedDeviceID, isDeviceAvailable(id) {
                return id
            }
            return findBestAvailableDevice() ?? 0
        }
    }
    
    private func setupDeviceChangeNotifications() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        
        let status = AudioObjectAddPropertyListener(
            systemObjectID,
            &address,
            { (_, _, _, userData) -> OSStatus in
                let manager = Unmanaged<AudioDeviceManager>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleDeviceListChange()
                }
                return noErr
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        if status != noErr {
            logger.error("Failed to add device change listener: \(status, privacy: .public)")
        }
    }
    
    private func handleDeviceListChange() {
        loadAvailableDevices { [weak self] in
            guard let self = self else { return }

            if self.inputMode == .systemDefault {
                self.notifyDeviceChange()
                return
            }

            if self.isRecordingActive {
                guard let currentID = self.selectedDeviceID else { return }

                if !self.isDeviceAvailable(currentID) {
                    self.logger.warning("🎙️ Recording device \(currentID, privacy: .public) no longer available - requesting switch")

                    let newDeviceID = self.findBestAvailableDevice()

                    if let deviceID = newDeviceID {
                        self.selectedDeviceID = deviceID
                        NotificationCenter.default.post(
                            name: .audioDeviceSwitchRequired,
                            object: nil,
                            userInfo: ["newDeviceID": deviceID]
                        )
                    } else {
                        self.logger.error("No audio input devices available!")
                        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)
                    }
                }
                return
            }

            if self.inputMode == .custom {
                self.reconcileCustomDeviceAfterListChange()
            }
        }
    }
    
    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        getDeviceStringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
    }

    func getDeviceModelUID(deviceID: AudioDeviceID) -> String? {
        getDeviceStringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyModelUID
        )
    }

    private func findAvailableDevice(uid: String, modelUID: String?) -> (id: AudioDeviceID, uid: String, name: String)? {
        if !uid.isEmpty, let found = availableDevices.first(where: { $0.uid == uid }) {
            return found
        }
        if let modelUID, !modelUID.isEmpty,
           let found = availableDevices.first(where: { getDeviceModelUID(deviceID: $0.id) == modelUID }) {
            return found
        }
        return nil
    }

    private func updateCustomDeviceHints(deviceID: AudioDeviceID, uid: String, modelUID: String? = nil) {
        UserDefaults.standard.selectedAudioDeviceUID = uid
        UserDefaults.standard.selectedAudioDeviceModelUID = modelUID ?? getDeviceModelUID(deviceID: deviceID)
    }

    private func reconcileCustomDeviceAfterListChange() {
        let savedUID = UserDefaults.standard.selectedAudioDeviceUID ?? ""
        let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID

        if let desired = findAvailableDevice(uid: savedUID, modelUID: savedModelUID) {
            if selectedDeviceID != desired.id {
                selectedDeviceID = desired.id
                if desired.uid != savedUID || savedModelUID == nil {
                    updateCustomDeviceHints(deviceID: desired.id, uid: desired.uid)
                }
                notifyDeviceChange()
            } else if savedModelUID == nil {
                updateCustomDeviceHints(deviceID: desired.id, uid: desired.uid)
            }
        } else if let currentID = selectedDeviceID, !isDeviceAvailable(currentID) {
            fallbackToDefaultDevice()
        }
    }
    
    deinit {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            { (_, _, _, userData) -> OSStatus in
                return noErr
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
    }
    
    private func createPropertyAddress(selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
    
    private func getDeviceStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        guard deviceID != 0 else { return nil }

        var address = createPropertyAddress(selector: selector, scope: scope)
        let storageSize = MemoryLayout<UnsafeRawPointer?>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: storageSize,
            alignment: MemoryLayout<UnsafeRawPointer?>.alignment
        )
        defer { storage.deallocate() }
        let emptyProperty: UnsafeRawPointer? = nil
        storage.storeBytes(of: emptyProperty, as: UnsafeRawPointer?.self)
        var propertySize = UInt32(storageSize)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            storage
        )

        guard status == noErr,
              CoreAudioByteContract.hasExactSize(propertySize, expectedBytes: storageSize),
              let propertyRef = storage.load(as: UnsafeRawPointer?.self) else {
            logger.error("Failed to get device property \(selector, privacy: .public) for device \(deviceID, privacy: .public): \(status, privacy: .public)")
            return nil
        }

        let property = Unmanaged<CFString>.fromOpaque(propertyRef).takeRetainedValue()
        return property as String
    }
    
    private func notifyDeviceChange() {
        NotificationCenter.default.post(name: NSNotification.Name("AudioDeviceChanged"), object: nil)
    }
} 
