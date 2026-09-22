import AirWhisperAudio
import AirWhisperCore
import AVFoundation
import Foundation
import XCTest
@testable import AirWhisper

@MainActor
private final class TestRecorder: MicrophoneTestRecording {
    var onFirstSamples: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onLimitReached: (() -> Void)?
    var onLevel: ((AudioLevel) -> Void)?
    var starts: [(String, TimeInterval, AudioCaptureMode)] = []
    var stops = 0
    var cancels = 0
    var holdStop = false
    var holdCancel = false
    var holdStart = false
    var microphoneOpen = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var cancelContinuation: CheckedContinuation<Void, Never>?
    var audio = CapturedAudio(samples: [Float](repeating: 0.1, count: 16_000))

    func start(deviceID: String, maximumDuration: TimeInterval, mode: AudioCaptureMode) async throws {
        starts.append((deviceID, maximumDuration, mode))
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        try Task.checkCancellation()
        microphoneOpen = true
        onFirstSamples?()
    }

    func stop() async throws -> CapturedAudio {
        stops += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        microphoneOpen = false
        return audio
    }

    func cancel() async {
        cancels += 1
        if holdCancel { await withCheckedContinuation { cancelContinuation = $0 } }
        microphoneOpen = false
    }
}

private actor TestTranscriber: MicrophoneTestTranscribing {
    var calls = 0
    var hold = false
    var continuation: CheckedContinuation<String, Error>?
    var response = " fixture words "
    nonisolated let cancellations = CancellationCount()

    func configure(hold: Bool) { self.hold = hold }
    func transcribe(_ audio: CapturedAudio, language: String) async throws -> String {
        calls += 1
        if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return response
    }
    nonisolated func cancel() { cancellations.increment() }
    func finish(_ result: String = "late stale text") {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class CancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class TestPlayback: MicrophoneTestPlaying {
    var plays = 0
    var stops = 0
    var hold = false
    var continuation: CheckedContinuation<Void, Error>?
    func play(_ audio: CapturedAudio) async throws {
        try Task.checkCancellation()
        plays += 1
        if hold { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func stop() {
        stops += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor TestDelay {
    private var waiting: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = (seconds, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func hasWaiter(_ seconds: TimeInterval) -> Bool { waiting.values.contains { $0.0 == seconds } }

    func fire(_ seconds: TimeInterval) {
        let matches = waiting.filter { $0.value.0 == seconds }
        for (id, entry) in matches {
            waiting.removeValue(forKey: id)
            entry.1.resume()
        }
    }

    private func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
}

@MainActor
final class MicrophoneTestControllerTests: XCTestCase {
    private let device = AudioInputDevice(id: "stable-display-mic", name: "Display Microphone")
    private var resolution: MicrophoneTestResolution {
        MicrophoneTestResolution(device: device, name: "Display Microphone · fixture", fallbackReason: nil)
    }

    func testMeterRequiresOnlyMicrophonePermissionAndNeverTranscribesOrRetainsSample() async {
        let recorder = TestRecorder()
        let transcriber = TestTranscriber()
        let playback = TestPlayback()
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: playback)
        test.start(row: .display("explicit-display"), resolution: resolution, record: false,
                   microphoneAuthorized: false, modelReady: false)
        XCTAssertFalse(test.isBusy)
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertNotNil(test.message)
        test.start(row: .display("explicit-display"), resolution: resolution, record: false,
                   microphoneAuthorized: true, modelReady: false)
        await eventually { test.phase == .metering }
        XCTAssertEqual(recorder.starts.first?.0, device.id)
        XCTAssertEqual(recorder.starts.first?.1, 30)
        XCTAssertEqual(recorder.starts.first?.2, .meterOnly)
        recorder.onLevel?(AudioLevel(rms: 0.25, peak: 0.5))
        XCTAssertTrue(test.level.hasSignal)
        test.stop()
        await eventually { !test.isBusy }
        let calls = await transcriber.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(transcriber.cancellations.value, 0, "Stopping a meter must not cancel shared model preparation.")
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(test.transcript)
        XCTAssertEqual(test.level, .silence)
        XCTAssertEqual(playback.plays, 0)
    }

    func testRecordRequiresModelAndClosesMicrophoneBeforeTranscriptionAndPlayback() async {
        let recorder = TestRecorder()
        recorder.holdStop = true
        let transcriber = TestTranscriber()
        let playback = TestPlayback()
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: playback)
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: false)
        XCTAssertFalse(test.isBusy)
        XCTAssertTrue(recorder.starts.isEmpty)
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        XCTAssertEqual(recorder.starts.first?.1, 10)
        XCTAssertEqual(recorder.starts.first?.2, .recording)
        test.stop()
        await eventually { recorder.stopContinuation != nil }
        XCTAssertEqual(test.phase, .stopping)
        let callsBeforeStop = await transcriber.calls
        XCTAssertEqual(callsBeforeStop, 0)
        test.play()
        XCTAssertEqual(playback.plays, 0)
        recorder.stopContinuation?.resume()
        recorder.stopContinuation = nil
        await eventually { !test.isBusy }
        XCTAssertFalse(recorder.microphoneOpen)
        XCTAssertEqual(test.transcript, "Fixture words")
        XCTAssertTrue(test.hasRecording)
        XCTAssertEqual(playback.plays, 0, "Recording never starts playback automatically.")
        test.play()
        await eventually { !test.isBusy }
        XCTAssertEqual(playback.plays, 1)
        test.clear()
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(test.transcript)
    }

    func testCancelKeepsOwnershipUntilCaptureAndInferenceDrainAndRejectsLateText() async {
        let recorder = TestRecorder()
        let transcriber = TestTranscriber()
        await transcriber.configure(hold: true)
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: TestPlayback())
        test.start(row: .fallback, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        test.stop()
        await eventually { test.phase == .transcribing }
        await eventuallyAsync { await transcriber.calls > 0 }
        recorder.holdCancel = true
        test.cancel()
        XCTAssertEqual(test.phase, .cancelling)
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(test.transcript)
        test.start(row: .fixed, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        XCTAssertEqual(recorder.starts.count, 1)
        await eventually { recorder.cancelContinuation != nil }
        recorder.cancelContinuation?.resume()
        recorder.cancelContinuation = nil
        XCTAssertTrue(test.isBusy, "Native inference still owns the shared model until it returns.")
        await transcriber.finish()
        await eventually { !test.isBusy }
        XCTAssertEqual(transcriber.cancellations.value, 1)
        XCTAssertNil(test.transcript)
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(recorder.onLevel)
    }

    func testCanceledPendingStartCannotOpenMicrophoneOrOverwriteNewerCallbacks() async {
        let recorder = TestRecorder()
        recorder.holdStart = true
        let test = MicrophoneTestController(recorder: recorder, transcriber: TestTranscriber(), playback: TestPlayback())
        test.start(row: .fallback, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { recorder.startContinuation != nil }
        let staleLevel = recorder.onLevel
        test.clear()
        XCTAssertTrue(test.isBusy)
        recorder.startContinuation?.resume()
        recorder.startContinuation = nil
        await eventually { !test.isBusy }
        XCTAssertFalse(recorder.microphoneOpen)
        recorder.holdStart = false
        test.start(row: .fixed, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { test.phase == .metering }
        staleLevel?(AudioLevel(rms: 0.9, peak: 1))
        XCTAssertEqual(test.level, .silence)
        recorder.onLevel?(AudioLevel(rms: 0.2, peak: 0.3))
        XCTAssertTrue(test.level.hasSignal)
        await test.shutdown()
    }

    func testDeviceDisconnectCancelsExactCandidateWithoutReplacement() async {
        let recorder = TestRecorder()
        let test = MicrophoneTestController(recorder: recorder, transcriber: TestTranscriber(), playback: TestPlayback())
        test.start(row: .display("left-display"), resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { test.phase == .metering }
        test.availableDevicesChanged([AudioInputDevice(id: "other", name: "Other microphone", isDefault: true)])
        await eventually { !test.isBusy }
        XCTAssertEqual(recorder.starts.count, 1)
        XCTAssertNotNil(test.message)
        XCTAssertFalse(test.hasRecording)
    }

    func testPlaybackStopBeforeScheduledStartCannotPlayLaterAndRetainsResult() async {
        let recorder = TestRecorder()
        let playback = TestPlayback()
        let test = MicrophoneTestController(recorder: recorder, transcriber: TestTranscriber(), playback: playback)
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        test.stop()
        await eventually { !test.isBusy }
        test.play()
        test.stop()
        await eventually { !test.isBusy }
        XCTAssertEqual(playback.plays, 0)
        XCTAssertTrue(test.hasRecording)
        XCTAssertEqual(test.transcript, "Fixture words")
        await test.shutdown()
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(test.transcript)
    }

    func testMeterLimitAndRecordingLimitHaveDifferentOutcomes() async {
        let recorder = TestRecorder()
        let transcriber = TestTranscriber()
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: TestPlayback())
        test.start(row: .fallback, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { test.phase == .metering }
        recorder.onLimitReached?()
        await eventually { !test.isBusy }
        XCTAssertFalse(test.hasRecording)
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        recorder.onLimitReached?()
        await eventually { !test.isBusy }
        XCTAssertTrue(test.hasRecording)
        XCTAssertEqual(test.transcript, "Fixture words")
        await test.shutdown()
    }

    func testSavedAndDraftRoutesUseExplicitRowWithoutSavingCandidate() throws {
        let left = AudioInputDevice(id: "left-mic", name: "Same model microphone")
        let right = AudioInputDevice(id: "right-mic", name: "Same model microphone")
        let fallback = AudioInputDevice(id: "built-in", name: "Built-in", isBuiltIn: true)
        let bluetooth = AudioInputDevice(id: "airpods", name: "AirPods", isDefault: true, isBluetooth: true)
        let devices = [left, right, fallback, bluetooth]
        var settings = DictationSettings()
        settings.screenMicrophones = ["left-display": left.id, "right-display": right.id]
        settings.fixedDeviceID = fallback.id
        let original = settings
        let saved = try XCTUnwrap(MicrophoneTestRouting.saved(row: .display("left-display"), devices: devices, settings: settings))
        XCTAssertEqual(saved.device.id, left.id)
        XCTAssertNil(saved.fallbackReason)
        let draft = try XCTUnwrap(MicrophoneTestRouting.candidate(row: .display("left-display"), candidateID: right.id, devices: devices, settings: settings))
        XCTAssertEqual(draft.device.id, right.id)
        XCTAssertNotEqual(draft.name, saved.name, "Same-named microphones retain distinct stable labels.")
        XCTAssertEqual(settings, original)
        let automatic = try XCTUnwrap(MicrophoneTestRouting.candidate(row: .display("left-display"), candidateID: nil, devices: devices, settings: settings))
        XCTAssertEqual(automatic.device.id, fallback.id)
        XCTAssertNotNil(automatic.fallbackReason)
        XCTAssertNil(MicrophoneTestRouting.candidate(row: .display("left-display"), candidateID: "unplugged", devices: devices, settings: settings))
        settings.screenMicrophones["left-display"] = "unplugged"
        XCTAssertNotNil(MicrophoneTestRouting.saved(row: .display("left-display"), devices: devices, settings: settings)?.fallbackReason)
        settings.fixedDeviceID = nil
        settings.screenMicrophones["left-display"] = fallback.id
        XCTAssertNil(MicrophoneTestRouting.saved(row: .display("left-display"), devices: devices, settings: settings)?.fallbackReason,
                     "An explicit built-in assignment is not a Bluetooth fallback.")
        XCTAssertEqual(MicrophoneTestRouting.candidate(row: .fallback, candidateID: nil, devices: devices, settings: settings)?.device.id, fallback.id)
    }

    func testDeferredModelPreparationWaitsForMeterCancellationDrain() async {
        let recorder = TestRecorder()
        recorder.holdCancel = true
        let transcriber = TestTranscriber()
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: TestPlayback())
        var pendingPreparation = false
        var preparations = 0
        test.onIdle = {
            XCTAssertFalse(test.isBusy)
            if pendingPreparation { pendingPreparation = false; preparations += 1 }
        }
        test.start(row: .fallback, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { test.phase == .metering }
        // A download finishing during metering queues preparation until ownership drains.
        pendingPreparation = true
        test.stop()
        await eventually { recorder.cancelContinuation != nil }
        XCTAssertEqual(preparations, 0)
        recorder.cancelContinuation?.resume()
        recorder.cancelContinuation = nil
        await eventually { !test.isBusy }
        XCTAssertEqual(preparations, 1)
        XCTAssertFalse(pendingPreparation)
        XCTAssertEqual(transcriber.cancellations.value, 0)
        test.onIdle = nil
    }

    func testStartAndStopDeadlinesCancelWithoutReleasingPendingNativeOwnership() async {
        let recorder = TestRecorder()
        recorder.holdStart = true
        let clock = TestDelay()
        let transcriber = TestTranscriber()
        let test = MicrophoneTestController(recorder: recorder, transcriber: transcriber, playback: TestPlayback(),
                                             sleep: { try await clock.sleep($0) })
        test.start(row: .fallback, resolution: resolution, record: false, microphoneAuthorized: true, modelReady: false)
        await eventually { recorder.startContinuation != nil }
        await eventuallyAsync { await clock.hasWaiter(35) }
        await clock.fire(35)
        await eventually { test.phase == .cancelling }
        XCTAssertTrue(test.isBusy)
        recorder.startContinuation?.resume()
        recorder.startContinuation = nil
        await eventually { !test.isBusy }
        XCTAssertFalse(recorder.microphoneOpen)
        XCTAssertNotNil(test.message)
        recorder.holdStart = false
        recorder.holdStop = true
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        test.stop()
        await eventually { recorder.stopContinuation != nil }
        await eventuallyAsync { await clock.hasWaiter(10) }
        await clock.fire(10)
        await eventually { test.phase == .cancelling }
        XCTAssertTrue(test.isBusy)
        recorder.stopContinuation?.resume()
        recorder.stopContinuation = nil
        await eventually { !test.isBusy }
        XCTAssertFalse(test.hasRecording)
        XCTAssertNil(test.transcript)
        let calls = await transcriber.calls
        XCTAssertEqual(calls, 0)
    }

    func testRetainedResultExpiresWithoutPlaybackOrAnotherCapture() async {
        let recorder = TestRecorder()
        let playback = TestPlayback()
        let clock = TestDelay()
        let test = MicrophoneTestController(recorder: recorder, transcriber: TestTranscriber(), playback: playback,
                                             sleep: { try await clock.sleep($0) })
        test.start(row: .fixed, resolution: resolution, record: true, microphoneAuthorized: true, modelReady: true)
        await eventually { test.phase == .recording }
        test.stop()
        await eventually { !test.isBusy }
        XCTAssertTrue(test.hasRecording)
        await eventuallyAsync { await clock.hasWaiter(300) }
        await clock.fire(300)
        await eventually { !test.hasRecording }
        XCTAssertNil(test.transcript)
        XCTAssertNil(test.row)
        XCTAssertEqual(recorder.starts.count, 1)
        XCTAssertEqual(playback.plays, 0)
    }

    func testWaveEncodingIsBoundedInMemoryAndRejectsInvalidSamples() throws {
        let encoded = try TestWaveData.encode(CapturedAudio(samples: [0, 1, -1]))
        XCTAssertEqual(encoded.count, 44 + 6)
        XCTAssertEqual(String(decoding: encoded.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: encoded[8..<12], as: UTF8.self), "WAVE")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("microphone-wave-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoded.write(to: url)
        let decoded = try AVAudioFile(forReading: url)
        XCTAssertEqual(decoded.length, 3)
        XCTAssertEqual(decoded.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(decoded.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 3))
        try decoded.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.floatChannelData?[0][0] ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(buffer.floatChannelData?[0][1] ?? .nan, 1, accuracy: 0.0001)
        XCTAssertEqual(buffer.floatChannelData?[0][2] ?? .nan, -1, accuracy: 0.0001)
        XCTAssertThrowsError(try TestWaveData.encode(CapturedAudio(samples: [.nan])))
        XCTAssertThrowsError(try TestWaveData.encode(CapturedAudio(samples: [])))
        XCTAssertThrowsError(try TestWaveData.encode(CapturedAudio(samples: [Float](repeating: 0, count: 160_001))))
    }

    private func eventuallyAsync(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Async condition did not become true", file: file, line: line)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}
