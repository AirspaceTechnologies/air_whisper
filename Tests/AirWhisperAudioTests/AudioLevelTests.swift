import AirWhisperCore
import XCTest
@testable import AirWhisperAudio

final class AudioLevelTests: XCTestCase {
    func testSilenceAndEmptyBuffersDoNotInventSignal() throws {
        var processor = try CaptureSampleProcessor(mode: .meterOnly, maximumDuration: 1)
        XCTAssertNil(try processor.append([], now: 0))
        XCTAssertEqual(processor.sampleCount, 0)
        let level = try XCTUnwrap(processor.append([Float](repeating: 0, count: 160), now: 0))
        XCTAssertEqual(level, .silence)
        XCTAssertEqual(level.normalized, 0)
        XCTAssertFalse(level.hasSignal)
        XCTAssertFalse(level.isClipping)
    }

    func testKnownToneHasExpectedRMSAndPeak() throws {
        var processor = try CaptureSampleProcessor(mode: .meterOnly, maximumDuration: 1)
        let samples = (0..<1_600).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.5) }
        let level = try XCTUnwrap(processor.append(samples, now: 0))
        XCTAssertEqual(level.rms, Float(0.5 / sqrt(2)), accuracy: 0.0001)
        XCTAssertEqual(level.peak, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(level.normalized, 0.8)
        XCTAssertLessThan(level.normalized, 0.9)
        XCTAssertTrue(level.hasSignal)
        XCTAssertFalse(level.isClipping)
    }

    func testFullScaleAndBelowFloorLevelsRemainBounded() throws {
        var loud = try CaptureSampleProcessor(mode: .meterOnly, maximumDuration: 1)
        let level = try XCTUnwrap(loud.append([1, -1, 1, -1], now: 0))
        XCTAssertEqual(level.rms, 1)
        XCTAssertEqual(level.peak, 1)
        XCTAssertEqual(level.normalized, 1)
        XCTAssertTrue(level.isClipping)
        let quiet = AudioLevel(rms: 0.00001, peak: 0.00001)
        XCTAssertEqual(quiet.normalized, 0)
        XCTAssertFalse(quiet.hasSignal)
        for invalid in [Float.nan, .infinity, -.infinity, -1, 2] {
            let checked = AudioLevel(rms: invalid, peak: invalid)
            XCTAssertTrue(checked.rms.isFinite)
            XCTAssertTrue(checked.peak.isFinite)
            XCTAssertTrue((0...1).contains(checked.normalized))
        }
    }

    func testMeterAggregatesAllSamplesBetweenThrottledUpdates() throws {
        var processor = try CaptureSampleProcessor(mode: .meterOnly, maximumDuration: 1)
        XCTAssertNotNil(try processor.append([Float](repeating: 0.2, count: 160), now: 10))
        XCTAssertNil(try processor.append([Float](repeating: 0.5, count: 80), now: 10.01))
        XCTAssertNil(try processor.append([Float](repeating: 0, count: 240), now: 10.05))
        let level = try XCTUnwrap(processor.append([Float](repeating: 0.5, count: 160), now: 10.11))
        XCTAssertEqual(level.rms, Float(sqrt(240.0 * 0.25 / 480)), accuracy: 0.0001)
        XCTAssertEqual(level.peak, 0.5)
        XCTAssertNil(try processor.append([Float](repeating: 1, count: 160), now: 10.12))
    }

    func testMeterOnlyCountsAndLimitsInputWithoutRetainingPCM() throws {
        var processor = try CaptureSampleProcessor(mode: .meterOnly, maximumDuration: 1)
        var events = 0
        for chunk in 0..<100 {
            if try processor.append([Float](repeating: 0.25, count: 160), now: Double(chunk) / 100) != nil {
                events += 1
            }
            XCTAssertTrue(processor.samples.isEmpty, "Preview must never retain a recording.")
        }
        XCTAssertTrue(processor.isFull)
        XCTAssertEqual(processor.sampleCount, CapturedAudio.sampleRate)
        XCTAssertTrue((9...11).contains(events), "UI updates should stay near ten per second, not one per input callback.")
        XCTAssertNil(try processor.append([Float](repeating: 1, count: 160), now: 2))
        XCTAssertEqual(processor.sampleCount, CapturedAudio.sampleRate)
        XCTAssertTrue(processor.samples.isEmpty)
    }

    func testRecordingRetainsOnlySamplesBeforeTheLimit() throws {
        var processor = try CaptureSampleProcessor(mode: .recording, maximumDuration: 0.1)
        _ = try processor.append([Float](repeating: 0.25, count: 1_500), now: 0)
        XCTAssertFalse(processor.isFull)
        _ = try processor.append([Float](repeating: 0.5, count: 1_000), now: 0.2)
        XCTAssertTrue(processor.isFull)
        XCTAssertEqual(processor.sampleCount, 1_600)
        XCTAssertEqual(processor.samples, [Float](repeating: 0.25, count: 1_500) + [Float](repeating: 0.5, count: 100))
        _ = try processor.append([1], now: 1)
        XCTAssertEqual(processor.samples.count, 1_600)
    }

    func testNonFiniteInputIsRejectedBeforeRetentionOrMeterUpdates() throws {
        for mode in [AudioCaptureMode.recording, .meterOnly] {
            for invalid in [Float.nan, .infinity, -.infinity] {
                var processor = try CaptureSampleProcessor(mode: mode, maximumDuration: 1)
                XCTAssertThrowsError(try processor.append([0.5, invalid], now: 0))
                XCTAssertEqual(processor.sampleCount, 0)
                XCTAssertTrue(processor.samples.isEmpty)
                XCTAssertEqual(try processor.append([0], now: 0), .silence)
            }
        }
    }

    func testBothModesRejectInvalidDurationBeforeCapture() {
        for mode in [AudioCaptureMode.recording, .meterOnly] {
            for duration in [0.0, -1, .nan, .infinity, 601] {
                XCTAssertThrowsError(try CaptureSampleProcessor(mode: mode, maximumDuration: duration))
            }
        }
    }
}
