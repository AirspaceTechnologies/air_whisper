import AirWhisperCore
import Foundation

public enum AudioCaptureMode: Equatable, Sendable {
    case recording
    /// Inspect levels without retaining PCM for transcription or playback.
    case meterOnly
}

/// Levels of the converted mono PCM used by transcription, not calibrated SPL.
public struct AudioLevel: Equatable, Sendable {
    public let rms: Float
    public let peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms.isFinite ? min(1, max(0, rms)) : 0
        self.peak = peak.isFinite ? min(1, max(self.rms, peak)) : self.rms
    }

    /// Maps -60...0 dBFS onto the display range. Values below the floor stay empty.
    public var normalized: Double {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(rms)) + 60) / 60))
    }

    public var hasSignal: Bool { rms > 0.001 }
    /// Converted input is at full scale; resampling can also cause this condition.
    public var isClipping: Bool { peak >= 0.999 }
    public static let silence = AudioLevel(rms: 0, peak: 0)
}

/// Scalar-only accumulator. Capture callback frequency does not dictate UI frequency.
private struct AudioLevelAccumulator {
    private var squares = 0.0
    private var peak: Float = 0
    private var count = 0
    private var lastEmission: TimeInterval?

    mutating func append(_ samples: ArraySlice<Float>, now: TimeInterval) -> AudioLevel? {
        guard !samples.isEmpty else { return nil }
        for sample in samples {
            let bounded = min(1, max(-1, sample))
            squares += Double(bounded) * Double(bounded)
            peak = max(peak, abs(bounded))
        }
        count += samples.count
        guard lastEmission == nil || now - lastEmission! >= 0.1 else { return nil }
        let level = AudioLevel(rms: Float(sqrt(squares / Double(count))), peak: peak)
        squares = 0
        peak = 0
        count = 0
        lastEmission = now
        return level
    }
}

/// Shared by the real capture worker and synthetic tests. Both modes count samples
/// against the duration cap, but meter-only mode never owns an audio sample array.
struct CaptureSampleProcessor {
    private var recording: LimitedAudioBuffer?
    private var meter = AudioLevelAccumulator()
    private let maximumSamples: Int
    private(set) var sampleCount = 0

    init(mode: AudioCaptureMode, maximumDuration: TimeInterval) throws {
        let limit = try LimitedAudioBuffer(maximumDuration: maximumDuration)
        maximumSamples = limit.maximumSamples
        recording = mode == .recording ? limit : nil
    }

    var samples: [Float] { recording?.samples ?? [] }
    var isFull: Bool { sampleCount >= maximumSamples }

    mutating func append(_ samples: [Float], now: TimeInterval) throws -> AudioLevel? {
        // Validate before retaining anything or updating the meter. The converter
        // already performs this check; keep this boundary safe for other callers.
        guard now.isFinite, samples.allSatisfy(\.isFinite) else { throw AudioRecordingError.conversionFailed }
        let accepted = samples.prefix(maximumSamples - sampleCount)
        sampleCount += accepted.count
        recording?.append(samples)
        return meter.append(accepted, now: now)
    }
}
