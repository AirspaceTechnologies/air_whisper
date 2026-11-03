import Foundation
import IOKit
import AirWhisperCore

/// Runs off the main actor on topology changes. No audio capture or permission prompts.
enum DisplayMicrophoneDiscovery {
    struct Display: Sendable { let id: String; let number: UInt32 }

    static func discover(displays: [Display], devices: [AudioInputDevice]) -> [String: String] {
        guard !displays.isEmpty else { return [:] }
        let identities = displayIdentities(profile: displayProfile(), displays: displays)
        let serials = Set(identities.map(\.serial))
        guard !serials.isEmpty else { return [:] }
        return DisplayMicrophoneMatching.match(displays: identities,
                                               connections: usbConnections(displaySerials: serials), devices: devices)
    }

    static func displayIdentities(profile: Data, displays: [Display]) -> [DisplayHardwareIdentity] {
        guard let root = (try? JSONSerialization.jsonObject(with: profile)) as? [String: Any],
              let graphics = root["SPDisplaysDataType"] as? [[String: Any]] else { return [] }
        return graphics.flatMap { $0["spdisplays_ndrvs"] as? [[String: Any]] ?? [] }.compactMap { entry in
            guard let numberText = entry["_spdisplays_displayID"] as? String,
                  let number = UInt32(numberText), let display = displays.first(where: { $0.number == number }),
                  let serial = entry["spdisplays_display-serial-number"] as? String, !serial.isEmpty else { return nil }
            return DisplayHardwareIdentity(id: display.id, serial: serial)
        }
    }

    private static func displayProfile() -> Data {
        // The public profiler exposes the manufacturer's serial, whereas CGDisplaySerialNumber
        // exposes a different EDID number on Studio Displays. Avoid private CoreDisplay APIs.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json", "-detailLevel", "mini"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : Data()
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private static func usbConnections(displaySerials: Set<String>) -> [DisplayAudioConnection] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DisplayAudioConnection] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard string(device, "USB Product Name") == "Studio Display",
                  let audioSerial = string(device, "USB Serial Number"), !audioSerial.isEmpty else { continue }
            var ancestor: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(device, kIOServicePlane, &ancestor) == KERN_SUCCESS else { continue }
            var ancestors = Set<String>()
            while ancestor != 0 {
                if IOObjectConformsTo(ancestor, "IOUSBHostDevice") != 0,
                   let serial = string(ancestor, "USB Serial Number"), displaySerials.contains(serial) {
                    ancestors.insert(serial)
                }
                var parent: io_registry_entry_t = 0
                let status = IORegistryEntryGetParentEntry(ancestor, kIOServicePlane, &parent)
                IOObjectRelease(ancestor)
                ancestor = status == KERN_SUCCESS ? parent : 0
            }
            for serial in ancestors { result.append(DisplayAudioConnection(displaySerial: serial, audioSerial: audioSerial)) }
        }
        return result
    }
}
