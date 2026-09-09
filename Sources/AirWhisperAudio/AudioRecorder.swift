import AirWhisperCore
import AVFoundation
import Foundation

public enum AudioRecordingError: LocalizedError {
    case permissionDenied, deviceUnavailable, alreadyRecording, invalidDuration
    case couldNotStart, conversionFailed, interrupted, deviceDisconnected, noFrames

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is required. Enable Air Whisper in System Settings → Privacy & Security → Microphone."
        case .deviceUnavailable: return "The selected microphone is unavailable. Choose a connected microphone in Settings."
        case .alreadyRecording: return "A recording is already in progress."
        case .invalidDuration: return "The recording limit must be greater than zero and at most ten minutes."
        case .couldNotStart: return "The microphone could not start. Check its connection and try again."
        case .conversionFailed: return "The microphone's audio could not be converted. Try another microphone."
        case .interrupted: return "Microphone recording was interrupted. Release the dictation key and try again."
        case .deviceDisconnected: return "The selected microphone disconnected while recording."
        case .noFrames: return "The microphone did not deliver audio. Check its connection and try again."
        }
    }
}

enum CaptureEvent {
    case firstSamples, failure(AudioRecordingError), limitReached
}

protocol AudioCaptureDriving: AnyObject {
    // Submit operations synchronously from the caller's actor before suspending.
    // Otherwise a generic-executor hop can reorder cancel ahead of its start.
    @MainActor
    func start(id: UUID, deviceID: String, maximumDuration: TimeInterval, event: @escaping (UUID, CaptureEvent) -> Void) async throws
    @MainActor
    func stop(id: UUID) async throws -> CapturedAudio
    @MainActor
    func cancel(id: UUID) async
    func shutdown()
}

@MainActor
public final class AudioRecorder {
    public var onFirstSamples: (() -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onLimitReached: (() -> Void)?

    private let driver: AudioCaptureDriving
    private let authorize: () async -> Bool
    private var activeID: UUID?
    // Keep ownership through asynchronous stop/cancel, after callbacks are invalidated.
    private var ownedID: UUID?

    public convenience init() {
        self.init(driver: CaptureWorker(), authorize: Self.requestMicrophoneAccess)
    }

    init(driver: AudioCaptureDriving, authorize: @escaping () async -> Bool) {
        self.driver = driver
        self.authorize = authorize
    }

    deinit { driver.shutdown() }

    public func start(deviceID: String, maximumDuration: TimeInterval) async throws {
        guard ownedID == nil else { throw AudioRecordingError.alreadyRecording }
        _ = try LimitedAudioBuffer(maximumDuration: maximumDuration)
        let id = UUID()
        activeID = id
        ownedID = id
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let granted = await authorize()
                try Task.checkCancellation()
                guard activeID == id else { throw CancellationError() }
                guard granted else { throw AudioRecordingError.permissionDenied }
                try await driver.start(id: id, deviceID: deviceID, maximumDuration: maximumDuration) { [weak self] eventID, event in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == eventID else { return }
                        switch event {
                        case .firstSamples: self.onFirstSamples?()
                        case .failure(let error): self.onFailure?(error.localizedDescription)
                        case .limitReached: self.onLimitReached?()
                        }
                    }
                }
                try Task.checkCancellation()
                guard activeID == id else { throw CancellationError() }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in await self?.cancel(id: id) }
            }
        } catch {
            if activeID == id { activeID = nil }
            await driver.cancel(id: id)
            if ownedID == id { ownedID = nil }
            throw error
        }
    }

    public func stop() async throws -> CapturedAudio {
        guard let id = activeID else { return CapturedAudio(samples: []) }
        activeID = nil
        defer { if ownedID == id { ownedID = nil } }
        return try await driver.stop(id: id)
    }

    public func cancel() async {
        guard let id = ownedID else { return }
        await cancel(id: id)
    }

    private func cancel(id: UUID) async {
        if activeID == id { activeID = nil }
        await driver.cancel(id: id)
        if ownedID == id { ownedID = nil }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }
}

/// Capture, conversion, timers, and cleanup all run on one queue, independent of UI responsiveness.
private final class CaptureWorker: NSObject, AudioCaptureDriving, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.airwhisper.capture", qos: .userInitiated)
    private var activeID: UUID?
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var converter: PCMConverter?
    private var buffer: LimitedAudioBuffer?
    private var failure: AudioRecordingError?
    private var firstSamplesSent = false
    private var event: ((UUID, CaptureEvent) -> Void)?
    private var limitTimer: DispatchSourceTimer?
    private var firstFrameTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    @MainActor
    func start(id: UUID, deviceID: String, maximumDuration: TimeInterval, event: @escaping (UUID, CaptureEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.activeID == nil else { throw AudioRecordingError.alreadyRecording }
                    let buffer = try LimitedAudioBuffer(maximumDuration: maximumDuration)
                    guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected, device.hasMediaType(.audio) else {
                        throw AudioRecordingError.deviceUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let session = AVCaptureSession()
                    let output = AVCaptureAudioDataOutput()
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw AudioRecordingError.couldNotStart
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw AudioRecordingError.couldNotStart
                    }
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    session.commitConfiguration()
                    self.activeID = id
                    self.session = session
                    self.output = output
                    self.buffer = buffer
                    self.converter = PCMConverter()
                    self.failure = nil
                    self.firstSamplesSent = false
                    self.event = event
                    self.observe(session: session, device: device, id: id)
                    self.scheduleTimers(id: id, maximumDuration: maximumDuration)
                    session.startRunning()
                    guard session.isRunning else { throw AudioRecordingError.couldNotStart }
                    continuation.resume()
                } catch {
                    if self.activeID == id { self.reset() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func stop(id: UUID) async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.activeID == id else {
                    continuation.resume(returning: CapturedAudio(samples: []))
                    return
                }
                defer { self.reset() }
                self.releaseMicrophone()
                do {
                    if let failure = self.failure { throw failure }
                    if let tail = try self.converter?.finish() { self.buffer?.append(tail) }
                    continuation.resume(returning: CapturedAudio(samples: self.buffer?.samples ?? []))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor
    func cancel(id: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.activeID == id { self.reset() }
                continuation.resume()
            }
        }
    }

    func shutdown() {
        queue.async { self.reset() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard self.output === output, let id = activeID, session != nil, failure == nil else { return }
        do {
            let samples = try converter?.convert(sampleBuffer) ?? []
            guard !samples.isEmpty else { return }
            buffer?.append(samples)
            if !firstSamplesSent {
                firstSamplesSent = true
                firstFrameTimer?.cancel()
                firstFrameTimer = nil
                event?(id, .firstSamples)
            }
            if buffer?.isFull == true { reachLimit(id: id) }
        } catch { fail(.conversionFailed, id: id) }
    }

    private func observe(session: AVCaptureSession, device: AVCaptureDevice, id: UUID) {
        let center = NotificationCenter.default
        for (name, object, error) in [
            (AVCaptureSession.runtimeErrorNotification, session as AnyObject, AudioRecordingError.interrupted),
            (AVCaptureSession.wasInterruptedNotification, session as AnyObject, AudioRecordingError.interrupted),
            (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject, AudioRecordingError.deviceDisconnected)
        ] {
            observers.append(center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.session != nil else { return }
                    self.fail(error, id: id)
                }
            })
        }
    }

    private func scheduleTimers(id: UUID, maximumDuration: TimeInterval) {
        let limit = DispatchSource.makeTimerSource(queue: queue)
        limit.schedule(deadline: .now() + maximumDuration, leeway: .milliseconds(20))
        limit.setEventHandler { [weak self] in self?.reachLimit(id: id) }
        limitTimer = limit
        limit.resume()

        let firstFrame = DispatchSource.makeTimerSource(queue: queue)
        firstFrame.schedule(deadline: .now() + min(5, maximumDuration), leeway: .milliseconds(20))
        firstFrame.setEventHandler { [weak self] in
            guard let self, self.session != nil, !self.firstSamplesSent else { return }
            self.fail(.noFrames, id: id)
        }
        firstFrameTimer = firstFrame
        firstFrame.resume()
    }

    private func reachLimit(id: UUID) {
        guard activeID == id, session != nil, failure == nil else { return }
        releaseMicrophone()
        do {
            if let tail = try converter?.finish() { buffer?.append(tail) }
        } catch {
            fail(.conversionFailed, id: id)
            return
        }
        event?(id, .limitReached)
    }

    private func fail(_ error: AudioRecordingError, id: UUID) {
        guard activeID == id, failure == nil else { return }
        failure = error
        releaseMicrophone()
        converter = nil
        buffer = nil
        event?(id, .failure(error))
    }

    private func releaseMicrophone() {
        limitTimer?.cancel()
        limitTimer = nil
        firstFrameTimer?.cancel()
        firstFrameTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        session?.stopRunning()
        session = nil
    }

    private func reset() {
        releaseMicrophone()
        activeID = nil
        converter = nil
        buffer = nil
        failure = nil
        event = nil
        firstSamplesSent = false
    }
}
