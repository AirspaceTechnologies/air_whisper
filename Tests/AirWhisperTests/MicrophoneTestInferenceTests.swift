import AirWhisperAudio
import AirWhisperCore
import AirWhisperSpeech
import Combine
import CryptoKit
import XCTest
@testable import AirWhisper

final class MicrophoneTestInferenceTests: XCTestCase {
    /// Exercises the Settings test flow with the real model and a pinned public
    /// recording. Never opens a microphone, plays sound, or inserts text.
    @MainActor
    func testPublicFixtureThroughSettingsTranscription() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["AIR_WHISPER_TEST_MODEL"],
              let fixturePath = environment["AIR_WHISPER_TEST_WAV"] else {
            throw XCTSkip("Set AIR_WHISPER_TEST_MODEL and AIR_WHISPER_TEST_WAV for inference validation.")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let hash = SHA256.hash(data: try Data(contentsOf: fixtureURL))
            .map { String(format: "%02x", $0) }.joined()
        guard hash == "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e" else {
            XCTFail("Use the pinned public whisper.cpp JFK fixture documented in ThirdParty/NOTICES.md.")
            return
        }
        let decoded = try FileAudioDecoder.decode(fixtureURL)
        let audio = CapturedAudio(samples: Array(decoded.samples.prefix(10 * CapturedAudio.sampleRate)))
        let opened = expectation(description: "Fixture input ready")
        let recorder = FixtureRecorder(audio: audio, opened: opened)
        let transcriber = WhisperTranscriber()
        try await transcriber.prepare(modelURL: URL(fileURLWithPath: modelPath))
        let tester = MicrophoneTestController(recorder: recorder, transcriber: transcriber,
                                              playback: ForbiddenPlayback())
        let recognized = expectation(description: "Settings receives recognized speech")
        let subscription = tester.$transcript.compactMap { $0 }.first().sink { _ in recognized.fulfill() }
        defer { subscription.cancel() }

        let device = AudioInputDevice(id: "public-fixture", name: "Public speech fixture")
        tester.start(row: .fixed,
                     resolution: MicrophoneTestResolution(device: device, name: device.name, fallbackReason: nil),
                     record: true, microphoneAuthorized: true, modelReady: true)
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(tester.phase, .recording)
        XCTAssertEqual(recorder.maximumDuration, 10)
        XCTAssertEqual(recorder.mode, .recording)
        XCTAssertEqual(recorder.deviceID, device.id)
        tester.stop()
        await fulfillment(of: [recognized], timeout: 60)
        XCTAssertTrue(recorder.stopped)
        XCTAssertEqual(tester.phase, .idle)
        XCTAssertTrue(tester.hasRecording)
        XCTAssertTrue(FixtureAssertion.contains(tester.transcript ?? "", expected: "ask not what your country can do for you"),
                      "The Settings test should recognize the known public phrase.")
        await tester.shutdown()
        XCTAssertFalse(tester.hasRecording)
        XCTAssertNil(tester.transcript)
        await transcriber.unload()
    }
}

@MainActor
private final class FixtureRecorder: MicrophoneTestRecording {
    var onFirstSamples: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onLimitReached: (() -> Void)?
    var onLevel: ((AudioLevel) -> Void)?
    private let audio: CapturedAudio
    private let opened: XCTestExpectation
    private(set) var maximumDuration: TimeInterval?
    private(set) var mode: AudioCaptureMode?
    private(set) var deviceID: String?
    private(set) var stopped = false

    init(audio: CapturedAudio, opened: XCTestExpectation) {
        self.audio = audio
        self.opened = opened
    }

    func start(deviceID: String, maximumDuration: TimeInterval, mode: AudioCaptureMode) async throws {
        self.deviceID = deviceID
        self.maximumDuration = maximumDuration
        self.mode = mode
        onFirstSamples?()
        opened.fulfill()
    }

    func stop() async throws -> CapturedAudio {
        stopped = true
        return audio
    }

    func cancel() async { stopped = true }
}

@MainActor
private final class ForbiddenPlayback: MicrophoneTestPlaying {
    func play(_ audio: CapturedAudio) async throws {
        XCTFail("A transcription test must not start playback automatically.")
    }
    func stop() {}
}
