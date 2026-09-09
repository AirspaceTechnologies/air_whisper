import AppKit
import AVFoundation
import XCTest
import AirWhisperCore
@testable import AirWhisper

final class AppIntegrationTests: XCTestCase {
    func testModifierUsesSideSpecificBitsAndSuppressesChords() {
        var gesture = ModifierGesture()
        let genericOption = CGEventFlags.maskAlternate.rawValue
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 58, flags: genericOption | 0x20), .none)
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 61, flags: genericOption | 0x20 | 0x40), .none)
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 61, flags: genericOption | 0x20), .release)
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 61, flags: genericOption | 0x40), .press)
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 61, flags: genericOption | 0x40), .none)
        XCTAssertEqual(gesture.ordinaryKey(), .cancel)
        XCTAssertEqual(gesture.flagsChanged(key: .rightalt, code: 61, flags: 0), .release)
        XCTAssertEqual(gesture.ordinaryKey(), .none)
    }

    func testMissedReleaseEmitsOnceAndFnCanRearm() {
        var gesture = ModifierGesture()
        XCTAssertEqual(gesture.flagsChanged(key: .fn, code: 63, flags: PushToTalkKey.fn.rawMask), .press)
        XCTAssertEqual(gesture.checkRelease(key: .fn, physicalFlags: PushToTalkKey.fn.rawMask), .none)
        XCTAssertEqual(gesture.checkRelease(key: .fn, physicalFlags: 0), .release)
        XCTAssertEqual(gesture.checkRelease(key: .fn, physicalFlags: 0), .none)
        XCTAssertEqual(gesture.flagsChanged(key: .fn, code: 63, flags: PushToTalkKey.fn.rawMask), .press)
        gesture.reset()
        XCTAssertFalse(gesture.isHeld)
    }

    func testExistingModifierChordDoesNotBeginFnDictation() {
        var gesture = ModifierGesture()
        let flags = PushToTalkKey.fn.rawMask | CGEventFlags.maskCommand.rawValue
        XCTAssertEqual(gesture.flagsChanged(key: .fn, code: 63, flags: flags), .none)
        XCTAssertEqual(gesture.flagsChanged(key: .fn, code: 63, flags: 0), .release)
    }

    @MainActor
    func testSettingsEnforceSpeechDurationAndFiniteTiming() {
        var input = DictationSettings()
        input.maximumDuration = 600
        input.minimumDuration = -1
        input.restoreDelay = .nan
        let checked = SettingsStore.validated(input)
        XCTAssertEqual(checked.maximumDuration, 120)
        XCTAssertEqual(checked.minimumDuration, 0.2)
        XCTAssertEqual(checked.restoreDelay, 0.3)
    }

    @MainActor
    func testNamedClipboardWriteKeepsOwnedGenerationAndNewOwnerChangesIt() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let ownedGeneration = pasteboard.clearContents()
        guard pasteboard.setString("owned fixture", forType: .string) else {
            throw XCTSkip("The test runner cannot access the named pasteboard service.")
        }
        XCTAssertEqual(pasteboard.changeCount, ownedGeneration,
                       "Inserting text relies on clearContents retaining ownership through setString.")
        let newerGeneration = pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("newer fixture", forType: .string))
        XCTAssertEqual(pasteboard.changeCount, newerGeneration)
        XCTAssertNotEqual(pasteboard.changeCount, ownedGeneration,
                          "A newer clipboard owner must prevent restoration of the old snapshot.")
    }

    @MainActor
    func testClipboardSnapshotPreservesMultipleItemsAndBinaryRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("fixture text", forType: .string)
        let binary = Data([0x89, 0x50, 0x4e, 0x47, 0, 0xff])
        first.setData(binary, forType: .png)
        let second = NSPasteboardItem()
        let custom = NSPasteboard.PasteboardType("com.airwhisper.fixture")
        second.setData(Data([0, 1, 2, 3]), forType: custom)
        guard pasteboard.writeObjects([first, second]) else {
            throw XCTSkip("The test runner cannot access the named pasteboard service.")
        }
        let saved = try XCTUnwrap(TextInsertion.ClipboardSnapshot(pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("temporary fixture", forType: .string)
        saved.restore(to: pasteboard)
        let restored = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].string(forType: .string), "fixture text")
        XCTAssertEqual(restored[0].data(forType: .png), binary)
        XCTAssertEqual(restored[1].data(forType: custom), Data([0, 1, 2, 3]))
    }

    func testFixtureDecoderResamplesStereoWithoutMicrophone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirWhisperFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("stereo.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for frame in 0..<48_000 {
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.25)
            buffer.floatChannelData?[0][frame] = sample
            buffer.floatChannelData?[1][frame] = sample
        }
        do {
            var fileSettings = format.settings
            fileSettings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: path, settings: fileSettings)
            try file.write(from: buffer)
        }
        let decoded = try FileAudioDecoder.decode(path)
        XCTAssertEqual(decoded.duration, 1, accuracy: 0.02)
        XCTAssertTrue(decoded.samples.allSatisfy { $0.isFinite && abs($0) <= 0.26 })
        XCTAssertTrue(decoded.samples.contains { abs($0) > 0.1 })
    }

    func testFixtureAssertionIgnoresPunctuationButRejectsMissingAndEmptyText() {
        XCTAssertTrue(FixtureAssertion.contains("Fixture, words! More text.", expected: "fixture words"))
        XCTAssertFalse(FixtureAssertion.contains("Fixture words.", expected: "unrelated phrase"))
        XCTAssertFalse(FixtureAssertion.contains("Fixture words.", expected: "!"))
    }

    func testDuplicateMicrophoneLabelsRemainDistinctAcrossEnumerationOrder() {
        let left = AudioInputDevice(id: "stable-left-display", name: "Studio Display Microphone")
        let right = AudioInputDevice(id: "stable-right-display", name: "Studio Display Microphone")
        let leftLabel = DeviceDisplayName.label(for: left, among: [left, right])
        XCTAssertNotEqual(leftLabel, DeviceDisplayName.label(for: right, among: [left, right]))
        XCTAssertEqual(leftLabel, DeviceDisplayName.label(for: left, among: [right, left]))
        XCTAssertEqual(DeviceDisplayName.label(for: left, among: [left]), left.name)
    }
}
