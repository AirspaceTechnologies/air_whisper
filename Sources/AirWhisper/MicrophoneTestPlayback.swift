import AirWhisperCore
import AVFoundation
import Foundation

/// WAV bytes and AVAudioPlayer's source stay in memory. No temporary recording file.
@MainActor
final class MicrophoneTestPlayback: NSObject, MicrophoneTestPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var operationID: UUID?
    private var continuation: CheckedContinuation<Void, Error>?

    func play(_ audio: CapturedAudio) async throws {
        try Task.checkCancellation()
        stop()
        let data = try TestWaveData.encode(audio)
        let id = UUID()
        let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        operationID = id
        self.player = player
        player.delegate = self
        defer { if operationID == id { finish(id: id, error: CancellationError()) } }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard player.prepareToPlay(), player.play() else {
                    finish(id: id, error: TestWaveData.Failure("The test sample could not be played."))
                    return
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        guard let id = operationID else { return }
        finish(id: id, error: CancellationError())
    }

    private func finish(id: UUID, error: Error?) {
        guard operationID == id else { return }
        operationID = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        let continuation = self.continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.operationID else { return }
            self.finish(id: id, error: flag ? nil : TestWaveData.Failure("Test playback did not finish successfully."))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.operationID else { return }
            self.finish(id: id, error: TestWaveData.Failure("The test sample could not be decoded for playback."))
        }
    }
}

enum TestWaveData {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func encode(_ audio: CapturedAudio) throws -> Data {
        guard !audio.samples.isEmpty, audio.duration <= 10,
              audio.samples.allSatisfy(\.isFinite) else {
            throw Failure("The test sample is empty or invalid.")
        }
        let byteCount = UInt32(audio.samples.count * 2)
        var result = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + byteCount)
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(UInt32(CapturedAudio.sampleRate))
        append(UInt32(CapturedAudio.sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(byteCount)
        for sample in audio.samples {
            append(Int16((max(-1, min(1, sample)) * 32_767).rounded()))
        }
        return result
    }
}
