import AirWhisperCore
import Combine
import XCTest
@testable import AirWhisperAudio

/// Uses injected permission and capture drivers; never opens a microphone or prompts for permission.
@MainActor
final class AudioRecorderTests: XCTestCase {
    func testMicrophoneMeterHandlesSilenceSpeechAndInvalidSamples() {
        XCTAssertEqual(AudioMeter.level([]), 0)
        XCTAssertEqual(AudioMeter.level([0, 0]), 0)
        XCTAssertEqual(AudioMeter.level([.nan]), 0)
        XCTAssertEqual(AudioMeter.level([.infinity]), 0)
        XCTAssertEqual(AudioMeter.level([0.001, -0.001]), 0, accuracy: 0.001)
        XCTAssertEqual(AudioMeter.level([0.1, -0.1]), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(AudioMeter.level([1, -1]), 1)
        XCTAssertEqual(AudioMeter.level([2]), 1)
    }

    func testMicrophoneTestStopsAtLimitAndCanRestart() async throws {
        let starting = expectation(description: "first test starting")
        let driver = FakeCaptureDriver(starting: starting)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        let tester = MicrophoneTester(recorder: recorder)
        tester.start(deviceID: "first")
        await fulfillment(of: [starting], timeout: 2)
        let firstID = try XCTUnwrap(driver.activeID)
        let metered = expectation(description: "live input level")
        let levelObservation = tester.$level.sink { if $0 == 0.75 { metered.fulfill() } }
        driver.emit(.level(0.75), id: firstID)
        await fulfillment(of: [metered], timeout: 2)
        levelObservation.cancel()

        let stopped = expectation(description: "test stops automatically")
        let stopObservation = tester.$deviceID.sink { if $0 == nil { stopped.fulfill() } }
        driver.emit(.limitReached, id: firstID)
        await fulfillment(of: [stopped], timeout: 2)
        stopObservation.cancel()
        XCTAssertNil(driver.activeID)
        XCTAssertFalse(tester.isRunning)
        XCTAssertEqual(tester.level, 0)

        // Do not reuse an already fulfilled startup expectation.
        driver.clearStartingExpectation()
        tester.start(deviceID: "second")
        XCTAssertEqual(tester.deviceID, "second")
        tester.start(deviceID: "third")
        XCTAssertEqual(tester.deviceID, "second", "Only one microphone test can own capture.")
        driver.emit(.level(1), id: firstID)
        driver.emit(.failure(.deviceDisconnected), id: firstID)
        await tester.stopAndWait()
        XCTAssertNil(driver.activeID)
        XCTAssertNil(tester.deviceID)
        XCTAssertEqual(tester.level, 0)
        XCTAssertFalse(tester.isStopping)
    }

    func testStoppingMicrophoneTestDuringStartupReleasesCapture() async throws {
        let starting = expectation(description: "test opening microphone")
        let driver = FakeCaptureDriver(starting: starting, suspendStart: true)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        let tester = MicrophoneTester(recorder: recorder)
        tester.start(deviceID: "first")
        await fulfillment(of: [starting], timeout: 2)
        tester.stop()
        XCTAssertTrue(tester.isStopping)
        driver.resumeStart()
        await tester.stopAndWait()
        XCTAssertNil(driver.activeID)
        XCTAssertNil(tester.deviceID)
        XCTAssertFalse(tester.isStopping)
    }

    func testMicrophoneGraphKeepsOnlyRecentLevelsAndResetsForNextDevice() async throws {
        let starting = expectation(description: "meter started")
        let driver = FakeCaptureDriver(starting: starting)
        let tester = MicrophoneTester(recorder: AudioRecorder(driver: driver, authorize: { true }))
        tester.start(deviceID: "first")
        await fulfillment(of: [starting], timeout: 2)
        let id = try XCTUnwrap(driver.activeID)
        let received = expectation(description: "latest level received")
        let observation = tester.$levelHistory.sink { if $0.last == 1 { received.fulfill() } }
        for _ in 0..<110 { driver.emit(.level(0.2), id: id) }
        driver.emit(.level(1), id: id)
        await fulfillment(of: [received], timeout: 2)
        observation.cancel()
        XCTAssertEqual(tester.levelHistory.count, 100)
        XCTAssertEqual(tester.levelHistory.last, 1)
        await tester.stopAndWait()
        XCTAssertEqual(tester.levelHistory.count, 100, "Keep the graph visible after automatic stop for comparison.")
        driver.clearStartingExpectation()
        tester.start(deviceID: "second")
        XCTAssertTrue(tester.levelHistory.isEmpty)
        await tester.stopAndWait()
    }

    func testAlreadyCancelledTaskDoesNotRequestPermission() async {
        let driver = FakeCaptureDriver()
        var permissionRequests = 0
        let recorder = AudioRecorder(driver: driver, authorize: {
            permissionRequests += 1
            return true
        })
        let start = Task { try await recorder.start(deviceID: "test", maximumDuration: 120) }
        start.cancel()
        await assertCancelled(start)
        XCTAssertEqual(permissionRequests, 0)
    }

    func testCancelDuringPermissionPromptCannotStartCaptureAfterApproval() async throws {
        let requested = expectation(description: "permission requested")
        let permission = DeferredPermission(requested: requested)
        let driver = FakeCaptureDriver()
        let recorder = AudioRecorder(driver: driver, authorize: { await permission.request() })
        let start = Task { try await recorder.start(deviceID: "test", maximumDuration: 120) }
        await fulfillment(of: [requested], timeout: 2)
        await recorder.cancel()
        await permission.resolve(true)
        await assertCancelled(start)
        let starts = driver.startCount
        XCTAssertEqual(starts, 0)
    }

    func testReleaseDuringPermissionPromptReturnsEmptyAndCannotStartLater() async throws {
        let requested = expectation(description: "permission requested")
        let permission = DeferredPermission(requested: requested)
        let driver = FakeCaptureDriver()
        let recorder = AudioRecorder(driver: driver, authorize: { await permission.request() })
        let start = Task { try await recorder.start(deviceID: "test", maximumDuration: 120) }
        await fulfillment(of: [requested], timeout: 2)
        let audio = try await recorder.stop()
        XCTAssertTrue(audio.samples.isEmpty)
        await permission.resolve(true)
        await assertCancelled(start)
        let starts = driver.startCount
        XCTAssertEqual(starts, 0)
    }

    func testCancelDuringDriverStartupReleasesThatSession() async throws {
        let starting = expectation(description: "capture starting")
        let driver = FakeCaptureDriver(starting: starting, suspendStart: true)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        let start = Task { try await recorder.start(deviceID: "test", maximumDuration: 120) }
        await fulfillment(of: [starting], timeout: 2)
        await recorder.cancel()
        driver.resumeStart()
        await assertCancelled(start)
        let active = driver.activeID
        XCTAssertNil(active)
    }

    func testReleaseDuringDriverStartupKeepsCollectedFrames() async throws {
        let starting = expectation(description: "capture starting")
        let driver = FakeCaptureDriver(starting: starting, suspendStart: true)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        let start = Task { try await recorder.start(deviceID: "test", maximumDuration: 120) }
        await fulfillment(of: [starting], timeout: 2)
        let audio = try await recorder.stop()
        XCTAssertEqual(audio.samples, [0.25])
        driver.resumeStart()
        await assertCancelled(start)
    }

    func testPermissionDenialDoesNotReachCaptureDriver() async {
        let driver = FakeCaptureDriver()
        let recorder = AudioRecorder(driver: driver, authorize: { false })
        do {
            try await recorder.start(deviceID: "test", maximumDuration: 120)
            XCTFail("Expected microphone permission failure")
        } catch {
            guard case AudioRecordingError.permissionDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let starts = driver.startCount
        XCTAssertEqual(starts, 0)
    }

    func testCancelStillReleasesCaptureWhileStopIsPending() async throws {
        let stopping = expectation(description: "capture stopping")
        let driver = FakeCaptureDriver(stopping: stopping, suspendStop: true)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        try await recorder.start(deviceID: "test", maximumDuration: 120)
        let stop = Task { try await recorder.stop() }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertNotNil(driver.activeID)
        await recorder.cancel()
        XCTAssertNil(driver.activeID)
        driver.resumeStop()
        _ = try await stop.value
    }

    func testNewCaptureCannotStartBeforePreviousStopCompletes() async throws {
        let stopping = expectation(description: "capture stopping")
        let driver = FakeCaptureDriver(stopping: stopping, suspendStop: true)
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        try await recorder.start(deviceID: "first", maximumDuration: 120)
        let stop = Task { try await recorder.stop() }
        await fulfillment(of: [stopping], timeout: 2)
        do {
            try await recorder.start(deviceID: "second", maximumDuration: 120)
            XCTFail("Capture restarted before microphone cleanup completed")
        } catch {
            guard case AudioRecordingError.alreadyRecording = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(driver.startCount, 1)
        driver.resumeStop()
        _ = try await stop.value
        try await recorder.start(deviceID: "second", maximumDuration: 120)
        XCTAssertEqual(driver.startCount, 2)
        await recorder.cancel()
    }

    func testOldCaptureCallbacksCannotAffectNewSession() async throws {
        let driver = FakeCaptureDriver()
        let recorder = AudioRecorder(driver: driver, authorize: { true })
        try await recorder.start(deviceID: "first", maximumDuration: 120)
        let firstID = driver.currentID()
        let oldID = try XCTUnwrap(firstID)
        _ = try await recorder.stop()
        try await recorder.start(deviceID: "second", maximumDuration: 120)
        let stale = expectation(description: "stale callback")
        stale.isInverted = true
        recorder.onFirstSamples = { stale.fulfill() }
        recorder.onFailure = { _ in stale.fulfill() }
        recorder.onLimitReached = { stale.fulfill() }
        driver.emit(.firstSamples, id: oldID)
        driver.emit(.failure(.interrupted), id: oldID)
        driver.emit(.limitReached, id: oldID)
        await fulfillment(of: [stale], timeout: 0.1)

        let current = expectation(description: "current first frames")
        recorder.onFirstSamples = { current.fulfill() }
        let secondID = driver.currentID()
        let newID = try XCTUnwrap(secondID)
        driver.emit(.firstSamples, id: newID)
        await fulfillment(of: [current], timeout: 2)
        await recorder.cancel()
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("Cancelled startup succeeded", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor DeferredPermission {
    let requested: XCTestExpectation
    var continuation: CheckedContinuation<Bool, Never>?
    init(requested: XCTestExpectation) { self.requested = requested }

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            requested.fulfill()
        }
    }

    func resolve(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

@MainActor
private final class FakeCaptureDriver: AudioCaptureDriving {
    private(set) var activeID: UUID?
    private(set) var startCount = 0
    private var starting: XCTestExpectation?
    private let suspendStart: Bool
    private let stopping: XCTestExpectation?
    private let suspendStop: Bool
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var pendingStop: CheckedContinuation<Void, Never>?
    private var handlers: [UUID: (UUID, CaptureEvent) -> Void] = [:]

    init(starting: XCTestExpectation? = nil, suspendStart: Bool = false,
         stopping: XCTestExpectation? = nil, suspendStop: Bool = false) {
        self.starting = starting
        self.suspendStart = suspendStart
        self.stopping = stopping
        self.suspendStop = suspendStop
    }

    func start(id: UUID, deviceID: String, maximumDuration: TimeInterval, event: @escaping (UUID, CaptureEvent) -> Void) async throws {
        activeID = id
        startCount += 1
        handlers[id] = event
        if suspendStart {
            await withCheckedContinuation { continuation in
                pendingStart = continuation
                starting?.fulfill()
            }
        } else { starting?.fulfill() }
    }

    func stop(id: UUID) async throws -> CapturedAudio {
        guard activeID == id else { return CapturedAudio(samples: []) }
        if suspendStop {
            await withCheckedContinuation { continuation in
                pendingStop = continuation
                stopping?.fulfill()
            }
        }
        if activeID == id { activeID = nil }
        return CapturedAudio(samples: [0.25])
    }

    func cancel(id: UUID) async {
        if activeID == id { activeID = nil }
    }

    func resumeStart() {
        pendingStart?.resume()
        pendingStart = nil
    }

    func resumeStop() {
        pendingStop?.resume()
        pendingStop = nil
    }

    func currentID() -> UUID? { activeID }
    func clearStartingExpectation() { starting = nil }
    func emit(_ event: CaptureEvent, id: UUID) { handlers[id]?(id, event) }
    nonisolated func shutdown() {}
}
