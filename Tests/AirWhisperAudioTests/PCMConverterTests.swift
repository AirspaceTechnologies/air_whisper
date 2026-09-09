import AirWhisperCore
import AVFoundation
import CoreMedia
import XCTest
@testable import AirWhisperAudio

final class PCMConverterTests: XCTestCase {
    func testResamplesStereoAt48kAndFlushesTail() throws {
        let converter = PCMConverter()
        let source = try makeSine(rate: 48_000, channels: 2, start: 0, frames: 48_000)
        let output = try converter.convert(source) + converter.finish()
        XCTAssertEqual(output.count, 16_000, accuracy: 2)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        let middle = output.dropFirst(256).dropLast(256)
        let rms = sqrt(middle.reduce(0.0) { $0 + Double($1 * $1) } / Double(middle.count))
        XCTAssertGreaterThan(rms, 0.1)
        XCTAssertLessThan(rms, 0.8)
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings) / (Double(middle.count) / 16_000), 440, accuracy: 3)
    }

    func testChunkingDoesNotResetResamplerAt44100Hz() throws {
        let wholeConverter = PCMConverter()
        let whole = try wholeConverter.convert(makeSine(rate: 44_100, channels: 1, start: 0, frames: 44_100)) + wholeConverter.finish()
        let chunkedConverter = PCMConverter()
        var chunked: [Float] = []
        for start in stride(from: 0, to: 44_100, by: 441) {
            chunked += try chunkedConverter.convert(makeSine(rate: 44_100, channels: 1, start: start, frames: 441))
        }
        chunked += try chunkedConverter.finish()
        XCTAssertEqual(chunked.count, whole.count)
        let greatestDifference = zip(chunked, whole).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(greatestDifference, 0.0001)
    }

    func testStereoDownmixIncludesBothChannels() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        input.frameLength = input.frameCapacity
        for index in 0..<4_800 {
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000) * 0.25)
            input.floatChannelData![0][index] = value
            input.floatChannelData![1][index] = -value
        }
        let converter = PCMConverter()
        let output = try converter.convert(input) + converter.finish()
        XCTAssertFalse(output.isEmpty)
        XCTAssertLessThan(output.map(abs).max() ?? 0, 0.0001)
    }

    func testCopiesCapturedInterleavedInt16SampleBuffer() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        pcm.frameLength = 160
        for index in 0..<160 { pcm.int16ChannelData![0][index] = 8_192 }
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 160, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        let sample = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sample), noErr)
        let converter = PCMConverter()
        let output = try converter.convert(sample) + converter.finish()
        XCTAssertEqual(output.count, 160)
        XCTAssertEqual(output[80], 0.25, accuracy: 0.0001)
    }

    func testDurationCapTruncatesAndNeverGrowsAfterLimit() throws {
        var buffer = try LimitedAudioBuffer(maximumDuration: 0.1)
        buffer.append(Array(repeating: 0.25, count: 1_500))
        XCTAssertFalse(buffer.isFull)
        buffer.append(Array(repeating: 0.5, count: 1_000))
        buffer.append(Array(repeating: 1, count: 1_000))
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.samples.count, 1_600)
        XCTAssertEqual(buffer.samples.last, 0.5)
    }

    func testFullScaleOvershootIsClampedBeforeInference() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        input.frameLength = 160
        for index in 0..<160 { input.floatChannelData![0][index] = index < 80 ? 1.2 : -1.2 }
        let converter = PCMConverter()
        let output = try converter.convert(input) + converter.finish()
        XCTAssertEqual(output.count, 160)
        XCTAssertEqual(output.max(), 1)
        XCTAssertEqual(output.min(), -1)
    }

    func testNonFiniteSamplesAreRejectedBeforeInference() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        input.frameLength = 160
        for index in 0..<160 { input.floatChannelData![0][index] = .nan }
        XCTAssertThrowsError(try PCMConverter().convert(input))
    }

    func testInvalidDurationCannotAllocateUnboundedMemory() {
        for duration in [0.0, -1, .infinity, .nan, 601] {
            XCTAssertThrowsError(try LimitedAudioBuffer(maximumDuration: duration))
        }
    }

    private func makeSine(rate: Double, channels: AVAudioChannelCount, start: Int, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        input.frameLength = input.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                input.floatChannelData![channel][frame] = Float(sin(2 * Double.pi * 440 * Double(start + frame) / rate) * 0.25)
            }
        }
        return input
    }
}
