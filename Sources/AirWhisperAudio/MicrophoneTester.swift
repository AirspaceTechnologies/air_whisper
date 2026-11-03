import AirWhisperCore
import Combine
import Foundation

/// An explicit, twenty-second microphone check. Captured samples are discarded on stop.
@MainActor
public final class MicrophoneTester: ObservableObject {
    @Published public private(set) var deviceID: String?
    @Published public private(set) var level: Float = 0
    @Published public private(set) var levelHistory: [Float] = []
    @Published public private(set) var status = ""
    @Published public private(set) var isStopping = false
    public var isRunning: Bool { deviceID != nil }

    private let recorder: AudioRecorder
    private var operationID: UUID?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    public convenience init() { self.init(recorder: AudioRecorder()) }
    init(recorder: AudioRecorder) { self.recorder = recorder }

    public func start(deviceID: String) {
        guard !isRunning else { return }
        let id = UUID()
        operationID = id
        self.deviceID = deviceID
        level = 0
        levelHistory = []
        status = "Opening microphone…"
        DictationDiagnostics.session.notice("microphone_test_start")
        recorder.onFirstSamples = { [weak self] in
            guard let self, self.operationID == id else { return }
            self.status = "Speak normally. The graph follows your voice. Stops after 20 seconds."
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.operationID == id else { return }
            self.level = level
            // Publish once per sample so observers never see an over-capacity history.
            self.levelHistory = Array((self.levelHistory + [level]).suffix(100))
        }
        recorder.onLimitReached = { [weak self] in
            guard let self, self.operationID == id else { return }
            self.stop(message: "Test finished. Try another microphone to compare.")
        }
        recorder.onFailure = { [weak self] message in
            guard let self, self.operationID == id else { return }
            self.stop(message: message)
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(deviceID: deviceID, maximumDuration: 20)
            } catch {
                guard self.operationID == id, !Task.isCancelled else { return }
                self.stop(message: error.localizedDescription)
            }
        }
    }

    public func stop() { stop(message: "Test stopped.") }

    public func stopAndWait() async {
        stop()
        await stopTask?.value
    }

    private func stop(message: String) {
        guard isRunning, !isStopping else { return }
        operationID = nil
        isStopping = true
        level = 0
        status = "Stopping microphone…"
        startTask?.cancel()
        let starting = startTask
        stopTask = Task { [weak self] in
            guard let self else { return }
            await self.recorder.cancel()
            await starting?.value
            self.startTask = nil
            self.deviceID = nil
            self.isStopping = false
            self.status = message
            DictationDiagnostics.session.notice("microphone_test_stopped")
        }
    }
}
