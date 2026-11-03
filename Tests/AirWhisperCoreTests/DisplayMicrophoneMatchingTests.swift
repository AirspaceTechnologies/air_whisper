import XCTest
@testable import AirWhisperCore

final class DisplayMicrophoneMatchingTests: XCTestCase {
    private let displays = [DisplayHardwareIdentity(id: "left", serial: "SCREEN-A"), DisplayHardwareIdentity(id: "right", serial: "SCREEN-B")]
    private let links = [DisplayAudioConnection(displaySerial: "SCREEN-A", audioSerial: "AUDIO-A"), DisplayAudioConnection(displaySerial: "SCREEN-B", audioSerial: "AUDIO-B")]
    private func microphone(_ serial: String, stream: String = "6,7") -> AudioInputDevice {
        AudioInputDevice(id: "AppleUSBAudioEngine:Apple Inc.:Studio Display:\(serial):\(stream)", name: "Studio Display Microphone")
    }

    func testIdenticalNamesMatchByHardwareIndependentOfOrder() {
        let a = microphone("AUDIO-A"), b = microphone("AUDIO-B")
        for devices in [[a, b], [b, a]] {
            XCTAssertEqual(DisplayMicrophoneMatching.match(displays: displays.reversed(), connections: links.reversed(), devices: devices), ["left": a.id, "right": b.id])
        }
    }

    func testDuplicateDisplaySerialIsNeverGuessed() {
        let ambiguous = [DisplayHardwareIdentity(id: "left", serial: "SCREEN-A"), DisplayHardwareIdentity(id: "right", serial: "SCREEN-A")]
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: ambiguous, connections: links, devices: [microphone("AUDIO-A")]).isEmpty)
    }

    func testDuplicateAudioIdentityAndMultipleCandidatesAreRejected() {
        let shared = [DisplayAudioConnection(displaySerial: "SCREEN-A", audioSerial: "SAME"), DisplayAudioConnection(displaySerial: "SCREEN-B", audioSerial: "SAME")]
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: displays, connections: shared, devices: [microphone("SAME")]).isEmpty)
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: displays, connections: links, devices: [microphone("AUDIO-A"), microphone("AUDIO-A", stream: "8")]).isEmpty)
    }

    func testMissingDisconnectedAndUnrelatedDevicesDoNotMatch() {
        let unrelated = AudioInputDevice(id: "other-driver:Apple Inc.:Studio Display:AUDIO-A:6,7", name: "Studio Display Microphone")
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: displays, connections: links, devices: [unrelated]).isEmpty)
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: displays, connections: [], devices: [microphone("AUDIO-A")]).isEmpty)
        XCTAssertTrue(DisplayMicrophoneMatching.match(displays: [DisplayHardwareIdentity(id: "unknown", serial: "")], connections: links, devices: [microphone("AUDIO-A")]).isEmpty)
    }

    func testAutomaticMatchReplacesLegacyAssignmentButRespectsExplicitOverride() {
        let a = microphone("AUDIO-A"), b = microphone("AUDIO-B")
        var settings = DictationSettings()
        settings.screenMicrophones["left"] = b.id
        let matches = ["left": a.id]
        let automatic = DeviceSelection.resolve(devices: [a, b], settings: settings, screenID: "left", automaticMicrophones: matches)
        XCTAssertEqual(automatic?.device, a)
        XCTAssertEqual(automatic?.source, .matchedDisplay)
        settings.displayMicrophoneOverrides = ["left": b.id]
        let override = DeviceSelection.resolve(devices: [a, b], settings: settings, screenID: "left", automaticMicrophones: matches)
        XCTAssertEqual(override?.device, b)
        XCTAssertEqual(override?.source, .assignedDisplay)
        settings.microphoneMode = .fixed
        settings.fixedDeviceID = b.id
        XCTAssertEqual(DeviceSelection.resolve(devices: [a, b], settings: settings, screenID: "left", automaticMicrophones: matches)?.device, b)
    }

    func testDisconnectedOverrideFallsBackToMatchedMicrophone() {
        let a = microphone("AUDIO-A")
        var settings = DictationSettings()
        settings.displayMicrophoneOverrides = ["left": "unplugged"]
        let selection = DeviceSelection.resolve(devices: [a], settings: settings, screenID: "left", automaticMicrophones: ["left": a.id])
        XCTAssertEqual(selection?.device, a)
        XCTAssertEqual(selection?.missingPreferredDevice, true)
    }

    func testExistingSettingsDecodeWithoutNewOverrideField() throws {
        var original = DictationSettings()
        original.screenMicrophones["left"] = "saved-microphone"
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "displayMicrophoneOverrides")
        let decoded = try JSONDecoder().decode(DictationSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.screenMicrophones, original.screenMicrophones)
        XCTAssertNil(decoded.displayMicrophoneOverrides)
    }
}
