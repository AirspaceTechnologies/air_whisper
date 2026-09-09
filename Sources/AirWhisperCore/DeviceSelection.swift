import Foundation

public struct DeviceSelection: Equatable, Sendable {
    public let device: AudioInputDevice
    public let missingPreferredDevice: Bool

    public static func resolve(devices: [AudioInputDevice], settings: DictationSettings, screenID: String?) -> DeviceSelection? {
        var preferredIDs: [String] = []
        if settings.microphoneMode == .auto, let screenID, let assigned = settings.screenMicrophones[screenID] {
            preferredIDs.append(assigned)
        }
        if let fixed = settings.fixedDeviceID { preferredIDs.append(fixed) }
        var missing = false
        for id in preferredIDs {
            if let device = devices.first(where: { $0.id == id }) {
                return DeviceSelection(device: device, missingPreferredDevice: missing)
            }
            missing = true
        }
        let systemDefault = devices.first(where: \.isDefault)
        // Only implicit fallback avoids Bluetooth's headset profile. Explicit choices win.
        let fallback: AudioInputDevice?
        if systemDefault?.isBluetooth == true {
            fallback = devices.first(where: \.isBuiltIn) ?? systemDefault
        } else {
            fallback = systemDefault ?? devices.first(where: \.isBuiltIn) ?? devices.first
        }
        return fallback.map { DeviceSelection(device: $0, missingPreferredDevice: missing) }
    }
}
