import XCTest
@testable import AirWhisperCore

final class CoreTests: XCTestCase {
    func testCleanupRemovesAnnotationsAndStandaloneFillers() {
        XCTAssertEqual(TextCleaner.clean("[BLANK_AUDIO]\nhello, UM, world\n(Music)"), "Hello, world")
        XCTAssertEqual(TextCleaner.clean("uh quantum numbers and thermal hum"), "Quantum numbers and thermal hum")
        XCTAssertEqual(TextCleaner.clean("über ah über"), "Über über")
    }

    func testSilenceHallucinationsAreNotInserted() {
        for text in ["", " \n", "(silence)", "[Music]", "thank you.", "Thanks for watching.", "you", "Thank you for watching.", "um uh hmm"] {
            XCTAssertNil(TextCleaner.clean(text), text)
        }
        XCTAssertEqual(TextCleaner.clean("Thank you for the review."), "Thank you for the review.")
    }

    func testDeviceIdentitySurvivesDuplicateNameReordering() {
        let left = AudioInputDevice(id: "left-uid", name: "Studio Display Microphone")
        let right = AudioInputDevice(id: "right-uid", name: "Studio Display Microphone")
        var settings = DictationSettings()
        settings.screenMicrophones["screen-left"] = left.id
        for devices in [[left, right], [right, left]] {
            XCTAssertEqual(DeviceSelection.resolve(devices: devices, settings: settings, screenID: "screen-left")?.device, left)
        }
    }

    func testFallbackHonorsExplicitBluetoothButPrefersBuiltInImplicitly() {
        let headset = AudioInputDevice(id: "headset", name: "Headset", isDefault: true, isBluetooth: true)
        let builtIn = AudioInputDevice(id: "builtin", name: "Mac microphone", isBuiltIn: true)
        let devices = [headset, builtIn]
        var settings = DictationSettings()
        XCTAssertEqual(DeviceSelection.resolve(devices: devices, settings: settings, screenID: nil)?.device, builtIn)
        settings.fixedDeviceID = headset.id
        XCTAssertEqual(DeviceSelection.resolve(devices: devices, settings: settings, screenID: nil)?.device, headset)
        settings.screenMicrophones["display"] = "unplugged"
        let selection = DeviceSelection.resolve(devices: devices, settings: settings, screenID: "display")
        XCTAssertEqual(selection?.device, headset)
        XCTAssertEqual(selection?.missingPreferredDevice, true)
        XCTAssertNil(DeviceSelection.resolve(devices: [], settings: settings, screenID: nil))
    }

    func testInvalidatedSessionCannotFinishNewSession() throws {
        var gate = SessionGate()
        let first = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin())
        gate.invalidate()
        let second = try XCTUnwrap(gate.begin())
        XCTAssertFalse(gate.contains(first))
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.contains(second))
        XCTAssertTrue(gate.finish(second))
        XCTAssertNil(gate.current)
    }

    func testHotkeyMasksDistinguishRightModifiers() {
        XCTAssertEqual(PushToTalkKey.fn.keyCode, 63)
        XCTAssertEqual(Set(PushToTalkKey.allCases.map(\.rawMask)).count, 4)
        XCTAssertEqual(PushToTalkKey.rightalt.rawMask & 0x20, 0) // left Option
        XCTAssertEqual(PushToTalkKey.rightcmd.rawMask & 0x08, 0) // left Command
        XCTAssertEqual(PushToTalkKey.rightctrl.rawMask & 0x01, 0) // left Control
    }

    func testVocabularyPromptFlattensLinesAndCapsLength() {
        XCTAssertEqual(VocabularyPrompt.sanitize("Aidan\nKubernetes\nQoder"), "Aidan, Kubernetes, Qoder")
        XCTAssertEqual(VocabularyPrompt.sanitize("  spaced  "), "spaced")
        XCTAssertEqual(VocabularyPrompt.sanitize(""), "")
        let long = String(repeating: "a", count: VocabularyPrompt.maximumLength + 50)
        XCTAssertEqual(VocabularyPrompt.sanitize(long).count, VocabularyPrompt.maximumLength)
    }
}
