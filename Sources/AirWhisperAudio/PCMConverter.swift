import AirWhisperCore
import AVFoundation
import CoreMedia
import Foundation

/// Stateful conversion preserves resampler history across capture callbacks.
/// This type is used exclusively on the recorder's serial queue.
final class PCMConverter {
    private let destination = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(CapturedAudio.sampleRate),
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else {
            throw AudioRecordingError.conversionFailed
        }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return [] }
        guard count <= Int(Int32.max) else { throw AudioRecordingError.conversionFailed }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioRecordingError.conversionFailed
        }
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else {
            throw AudioRecordingError.conversionFailed
        }
        return try convert(pcm)
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecordingError.conversionFailed
        }
        var result: [Float] = []
        if sourceFormat != format {
            result = try finish()
            guard let newConverter = AVAudioConverter(from: format, to: destination) else {
                throw AudioRecordingError.conversionFailed
            }
            newConverter.downmix = true
            newConverter.primeMethod = .normal
            converter = newConverter
            sourceFormat = format
        }
        guard let converter else { throw AudioRecordingError.conversionFailed }
        let estimate = ceil(Double(buffer.frameLength) * destination.sampleRate / format.sampleRate) + 256
        guard estimate < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: AVAudioFrameCount(estimate)) else {
            throw AudioRecordingError.conversionFailed
        }
        var supplied = false
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { throw AudioRecordingError.conversionFailed }
            try append(output, to: &result)
            if status != .haveData { break }
        }
        return result
    }

    /// Drains the resampler on release, so the last syllable is retained.
    func finish() throws -> [Float] {
        guard let converter else { return [] }
        defer {
            self.converter = nil
            sourceFormat = nil
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 4_096) else {
            throw AudioRecordingError.conversionFailed
        }
        var result: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { throw AudioRecordingError.conversionFailed }
            try append(output, to: &result)
            if status != .haveData { break }
        }
        return result
    }

    private func append(_ buffer: AVAudioPCMBuffer, to result: inout [Float]) throws {
        guard let channel = buffer.floatChannelData?[0] else { throw AudioRecordingError.conversionFailed }
        let values = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        guard values.allSatisfy(\.isFinite) else { throw AudioRecordingError.conversionFailed }
        // Band-limited resampling may overshoot full scale even when the input did not.
        result.append(contentsOf: values.map { min(1, max(-1, $0)) })
    }
}

/// A second cap on the sample count bounds memory even if capture timestamps are wrong.
struct LimitedAudioBuffer {
    let maximumSamples: Int
    private(set) var samples: [Float] = []
    var isFull: Bool { samples.count >= maximumSamples }

    init(maximumDuration: TimeInterval) throws {
        // A ten-minute ceiling also protects callers outside the settings UI from unbounded allocation.
        guard maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 600 else {
            throw AudioRecordingError.invalidDuration
        }
        maximumSamples = max(1, Int(floor(maximumDuration * Double(CapturedAudio.sampleRate))))
    }

    mutating func append(_ incoming: [Float]) {
        samples.append(contentsOf: incoming.prefix(maximumSamples - samples.count))
    }
}
