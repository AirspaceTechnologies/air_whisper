import Foundation

public struct DisplayHardwareIdentity: Sendable {
    public let id: String
    public let serial: String
    public init(id: String, serial: String) { self.id = id; self.serial = serial }
}

public struct DisplayAudioConnection: Sendable, Hashable {
    public let displaySerial: String
    public let audioSerial: String
    public init(displaySerial: String, audioSerial: String) {
        self.displaySerial = displaySerial; self.audioSerial = audioSerial
    }
}

/// Match identities, never names, ordering, volume, or port numbers. Ambiguity falls back.
public enum DisplayMicrophoneMatching {
    public static func match(displays: [DisplayHardwareIdentity], connections: [DisplayAudioConnection],
                             devices: [AudioInputDevice]) -> [String: String] {
        var result: [String: String] = [:]
        let connections = Set(connections)
        for display in displays where !display.serial.isEmpty {
            guard displays.filter({ $0.serial == display.serial }).count == 1 else { continue }
            let links = connections.filter { $0.displaySerial == display.serial && !$0.audioSerial.isEmpty }
            guard links.count == 1, let link = links.first,
                  connections.filter({ $0.audioSerial == link.audioSerial }).count == 1 else { continue }
            let candidates = devices.filter { device in
                let parts = device.id.components(separatedBy: ":")
                return parts.count == 5 && parts[0] == "AppleUSBAudioEngine"
                    && parts[1] == "Apple Inc." && parts[2] == "Studio Display"
                    && parts[3] == link.audioSerial
            }
            if candidates.count == 1 { result[display.id] = candidates[0].id }
        }
        return result
    }
}
