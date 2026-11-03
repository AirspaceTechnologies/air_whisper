import Foundation

public struct DeviceSelection: Equatable, Sendable {
    public enum Source: Sendable { case matchedDisplay, assignedDisplay, fallback, systemDefault }
    public let device: AudioInputDevice
    public let missingPreferredDevice: Bool
    public let source: Source

    public static func resolve(devices: [AudioInputDevice], settings: DictationSettings, screenID: String?,
                               automaticMicrophones: [String: String] = [:]) -> DeviceSelection? {
        var preferredIDs: [(String, Source)] = []
        if settings.microphoneMode == .auto, let screenID {
            if let override = settings.displayMicrophoneOverrides?[screenID] { preferredIDs.append((override, .assignedDisplay)) }
            if let matched = automaticMicrophones[screenID] { preferredIDs.append((matched, .matchedDisplay)) }
            else if let assigned = settings.screenMicrophones[screenID] { preferredIDs.append((assigned, .assignedDisplay)) }
        }
        if let fixed = settings.fixedDeviceID { preferredIDs.append((fixed, .fallback)) }
        var missing = false
        for (id, source) in preferredIDs {
            if let device = devices.first(where: { $0.id == id }) {
                return DeviceSelection(device: device, missingPreferredDevice: missing, source: source)
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
        return fallback.map { DeviceSelection(device: $0, missingPreferredDevice: missing, source: .systemDefault) }
    }
}
