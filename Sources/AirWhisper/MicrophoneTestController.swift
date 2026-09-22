import AirWhisperAudio
import AirWhisperCore
import AirWhisperSpeech
import Combine
import Foundation

/// A settings row, never the display containing the Settings window.
enum MicrophoneTestRow: Hashable {
    case display(String), fallback, fixed
}

struct MicrophoneTestResolution: Equatable {
    let device: AudioInputDevice
    let name: String
    let fallbackReason: String?
}

enum MicrophoneTestRouting {
    static func saved(row: MicrophoneTestRow, devices: [AudioInputDevice], settings: DictationSettings) -> MicrophoneTestResolution? {
        var draft = settings
        let displayID: String?
        switch row {
        case .display(let id): draft.microphoneMode = .auto; displayID = id
        case .fallback, .fixed: draft.microphoneMode = .fixed; displayID = nil
        }
        return resolve(devices: devices, settings: draft, displayID: displayID)
    }

    /// nil is this row's Automatic choice, not its previously saved assignment.
    static func candidate(row: MicrophoneTestRow, candidateID: String?, devices: [AudioInputDevice],
                          settings: DictationSettings) -> MicrophoneTestResolution? {
        if let candidateID {
            guard let device = devices.first(where: { $0.id == candidateID }) else { return nil }
            return MicrophoneTestResolution(device: device, name: DeviceDisplayName.label(for: device, among: devices), fallbackReason: nil)
        }
        var draft = settings
        let displayID: String?
        switch row {
        case .display(let id):
            draft.microphoneMode = .auto
            draft.screenMicrophones.removeValue(forKey: id)
            displayID = id
        case .fallback, .fixed:
            draft.microphoneMode = .fixed
            draft.fixedDeviceID = nil
            displayID = nil
        }
        return resolve(devices: devices, settings: draft, displayID: displayID)
    }

    private static func resolve(devices: [AudioInputDevice], settings: DictationSettings,
                                displayID: String?) -> MicrophoneTestResolution? {
        guard let choice = DeviceSelection.resolve(devices: devices, settings: settings, screenID: displayID) else { return nil }
        let reason: String?
        if let displayID, settings.screenMicrophones[displayID] == choice.device.id {
            reason = nil // Explicit display choices win, including Bluetooth or built-in.
        } else if choice.missingPreferredDevice {
            reason = "A saved microphone is unavailable; this is the available fallback."
        } else if let displayID, settings.screenMicrophones[displayID] == nil {
            reason = "No microphone is assigned to this display; using the fallback choice."
        } else if settings.fixedDeviceID == nil, choice.device.isBuiltIn, devices.first(where: \.isDefault)?.isBluetooth == true {
            reason = "Using the built-in microphone to preserve Bluetooth playback quality."
        } else if settings.fixedDeviceID == nil {
            reason = "Using the available automatic microphone choice."
        } else { reason = nil }
        return MicrophoneTestResolution(device: choice.device, name: DeviceDisplayName.label(for: choice.device, among: devices), fallbackReason: reason)
    }
}

@MainActor
protocol MicrophoneTestRecording: AnyObject {
    var onFirstSamples: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onLimitReached: (() -> Void)? { get set }
    var onLevel: ((AudioLevel) -> Void)? { get set }
    func start(deviceID: String, maximumDuration: TimeInterval, mode: AudioCaptureMode) async throws
    func stop() async throws -> CapturedAudio
    func cancel() async
}

extension AudioRecorder: MicrophoneTestRecording {}

protocol MicrophoneTestTranscribing: Sendable {
    func transcribe(_ audio: CapturedAudio, language: String) async throws -> String
    func cancel()
}

extension WhisperTranscriber: MicrophoneTestTranscribing {}

@MainActor
protocol MicrophoneTestPlaying: AnyObject {
    func play(_ audio: CapturedAudio) async throws
    func stop()
}

/// Owns the shared recorder/transcriber only while a test is active. No insertion,
/// clipboard, target-field, disk recording, or application transcript-history API
/// exists here. Cancellation keeps ownership until all pending native work drains.
@MainActor
final class MicrophoneTestController: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, metering, recording, stopping, transcribing, playing, cancelling

        var title: String {
            switch self {
            case .idle: return "Microphone test ready"
            case .starting: return "Opening test microphone…"
            case .metering: return "Testing microphone level…"
            case .recording: return "Recording test…"
            case .stopping: return "Stopping test…"
            case .transcribing: return "Transcribing test…"
            case .playing: return "Playing test recording…"
            case .cancelling: return "Cancelling test…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var row: MicrophoneTestRow?
    @Published private(set) var level: AudioLevel = .silence
    @Published private(set) var actualDeviceID: String?
    @Published private(set) var actualMicrophone = ""
    @Published private(set) var fallbackReason: String?
    @Published private(set) var transcript: String?
    @Published private(set) var message: String?
    @Published private(set) var hasRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var maximumDuration: TimeInterval = 30

    /// Called only after recorder/playback/inference ownership has fully drained.
    var onIdle: (() -> Void)?

    var isBusy: Bool { phase != .idle }
    var canStop: Bool { isBusy && phase != .cancelling }
    var canPlay: Bool { !isBusy && hasRecording }

    private let recorder: any MicrophoneTestRecording
    private let transcriber: any MicrophoneTestTranscribing
    private let playback: any MicrophoneTestPlaying
    private let resultLifetime: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var operationID: UUID?
    private var recordingRequested = false
    private var inferenceActive = false
    private var sample: CapturedAudio?
    private var captureTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(recorder: any MicrophoneTestRecording, transcriber: any MicrophoneTestTranscribing,
         playback: any MicrophoneTestPlaying, resultLifetime: TimeInterval = 300,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.playback = playback
        self.resultLifetime = resultLifetime
        self.sleep = sleep
    }

    func start(row: MicrophoneTestRow, resolution: MicrophoneTestResolution, record: Bool,
               microphoneAuthorized: Bool, modelReady: Bool) {
        guard !isBusy else { return }
        clearRetainedResult()
        self.row = row
        actualDeviceID = resolution.device.id
        actualMicrophone = resolution.name
        fallbackReason = resolution.fallbackReason
        message = nil
        guard microphoneAuthorized else {
            message = "Allow Microphone access in Setup before testing. Accessibility access is not needed for this test."
            return
        }
        guard !record || modelReady else {
            message = "Prepare a transcription model in Setup before recording a test. You can still test the microphone level."
            return
        }
        let id = UUID()
        operationID = id
        recordingRequested = record
        maximumDuration = record ? 10 : 30
        startedAt = Date()
        level = .silence
        phase = .starting
        recorder.onFirstSamples = { [weak self] in
            guard let self, self.operationID == id, self.phase == .starting else { return }
            self.phase = record ? .recording : .metering
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.operationID == id,
                  [.starting, .metering, .recording].contains(self.phase) else { return }
            self.level = level
        }
        recorder.onFailure = { [weak self] problem in
            guard let self, self.operationID == id else { return }
            self.cancel(message: problem)
        }
        recorder.onLimitReached = { [weak self] in
            guard let self, self.operationID == id else { return }
            self.stop()
        }
        // The audio worker enforces its own capture limit independently of the UI.
        // This also bounds a start/authorization that never produces first samples.
        setDeadline(seconds: maximumDuration + 5, id: id, message: "The microphone test timed out. Try again after checking the device.")
        captureTask = Task { [weak self] in
            guard let self, self.operationID == id, !Task.isCancelled else { return }
            do {
                try await self.recorder.start(deviceID: resolution.device.id,
                                              maximumDuration: self.maximumDuration,
                                              mode: record ? .recording : .meterOnly)
            } catch {
                guard self.operationID == id, !Task.isCancelled else { return }
                self.cancel(message: "Microphone test could not start: \(error.localizedDescription)")
            }
        }
    }

    /// Stop recording and transcribe, stop a meter, or stop playback. Cancel/Clear
    /// instead discards any audio and text and waits for ownership to be released.
    func stop() {
        switch phase {
        case .recording:
            finishRecording()
        case .metering, .starting:
            cancel(message: phase == .starting ? "Test stopped before audio was ready." : nil)
        case .playing:
            cancel(message: nil, preserveResult: true)
        case .transcribing, .stopping:
            cancel()
        case .idle, .cancelling:
            break
        }
    }

    private func finishRecording() {
        guard let id = operationID, recordingRequested, phase == .recording else { return }
        phase = .stopping
        setDeadline(seconds: 10, id: id, message: "The test microphone did not finish stopping. Check the device before trying again.")
        let pendingStart = captureTask
        workTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            guard self.operationID == id, !Task.isCancelled else { return }
            do {
                let audio = try await self.recorder.stop()
                guard self.operationID == id, !Task.isCancelled else { return }
                self.clearCaptureCallbacks()
                self.level = .silence
                self.startedAt = nil
                guard audio.duration >= 0.15 else {
                    self.finish(id: id, message: "The sample was too short. Wait for Recording, then speak.")
                    return
                }
                self.sample = audio
                self.hasRecording = true
                self.phase = .transcribing
                self.inferenceActive = true
                self.setDeadline(seconds: 45, id: id, message: "Test transcription timed out. Try a shorter sample.")
                do {
                    let raw = try await self.transcriber.transcribe(audio, language: "en")
                    self.inferenceActive = false
                    guard self.operationID == id, !Task.isCancelled else { return }
                    self.transcript = TextCleaner.clean(raw)
                    self.finish(id: id, message: self.transcript == nil ? "No speech was recognized. Play the sample to check what the microphone captured." : nil)
                } catch {
                    self.inferenceActive = false
                    guard self.operationID == id, !Task.isCancelled else { return }
                    self.finish(id: id, message: "Test transcription failed: \(error.localizedDescription)")
                }
            } catch {
                guard self.operationID == id, !Task.isCancelled else { return }
                self.cancel(message: "Microphone test failed: \(error.localizedDescription)")
            }
        }
    }

    func play() {
        guard !isBusy, let sample else { return }
        let id = UUID()
        operationID = id
        expiryTask?.cancel()
        message = nil
        phase = .playing
        setDeadline(seconds: 15, id: id, message: "Playback timed out.")
        workTask = Task { [weak self] in
            guard let self, self.operationID == id, !Task.isCancelled else { return }
            do {
                try await self.playback.play(sample)
                guard self.operationID == id, !Task.isCancelled else { return }
                self.finish(id: id)
            } catch {
                guard self.operationID == id, !Task.isCancelled else { return }
                self.finish(id: id, message: error is CancellationError ? nil : "Test playback failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel(message: String? = nil) {
        cancel(message: message, preserveResult: false)
    }

    private func cancel(message: String?, preserveResult: Bool) {
        if !preserveResult { clearRetainedResult() }
        self.message = message
        guard isBusy else {
            level = .silence
            startedAt = nil
            return
        }
        guard phase != .cancelling else { return }
        operationID = nil
        phase = .cancelling
        deadlineTask?.cancel()
        captureTask?.cancel()
        workTask?.cancel()
        // A meter may coexist with model preparation. Only cancel native inference
        // when this test actually started it; never cancel another model operation.
        if inferenceActive { transcriber.cancel() }
        playback.stop()
        let pendingStart = captureTask
        let pendingWork = workTask
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            await self.recorder.cancel()
            await pendingStart?.value
            await pendingWork?.value
            self.clearCaptureCallbacks()
            self.inferenceActive = false
            self.captureTask = nil
            self.workTask = nil
            self.cancellationTask = nil
            self.level = .silence
            self.startedAt = nil
            self.phase = .idle
            if self.hasRecording || self.transcript != nil { self.expireResultLater() }
            self.onIdle?()
        }
    }

    func clear() {
        cancel()
        row = nil
        actualDeviceID = nil
        actualMicrophone = ""
        fallbackReason = nil
    }

    func showUnavailable(_ explanation: String) {
        guard !isBusy else { return }
        clearRetainedResult()
        message = explanation
    }

    func availableDevicesChanged(_ devices: [AudioInputDevice]) {
        guard let actualDeviceID else { return }
        if !devices.contains(where: { $0.id == actualDeviceID }) {
            cancel(message: "The test microphone disconnected. Choose a connected microphone and start a new test.")
        } else if !isBusy {
            clear()
        }
    }

    func shutdown() async {
        clear()
        await cancellationTask?.value
    }

    private func finish(id: UUID, message: String? = nil) {
        guard operationID == id else { return }
        operationID = nil
        deadlineTask?.cancel()
        clearCaptureCallbacks()
        captureTask = nil
        workTask = nil
        startedAt = nil
        level = .silence
        self.message = message
        phase = .idle
        if hasRecording || transcript != nil { expireResultLater() }
        onIdle?()
    }

    private func clearCaptureCallbacks() {
        recorder.onFirstSamples = nil
        recorder.onLevel = nil
        recorder.onFailure = nil
        recorder.onLimitReached = nil
    }

    private func clearRetainedResult() {
        expiryTask?.cancel()
        expiryTask = nil
        sample = nil
        hasRecording = false
        transcript = nil
    }

    private func expireResultLater() {
        let sleep = self.sleep
        expiryTask = Task { [weak self] in
            do { try await sleep(self?.resultLifetime ?? 300) } catch { return }
            guard !Task.isCancelled, let self, !self.isBusy else { return }
            self.clear()
        }
    }

    private func setDeadline(seconds: TimeInterval, id: UUID, message: String) {
        deadlineTask?.cancel()
        let sleep = self.sleep
        deadlineTask = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            guard !Task.isCancelled, let self, self.operationID == id else { return }
            self.cancel(message: message)
        }
    }
}
