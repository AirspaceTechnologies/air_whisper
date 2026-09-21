import AirWhisperCore
import AVFoundation
import CryptoKit
import Foundation
import XCTest
import whisper
@testable import AirWhisperSpeech

final class SpeechTests: XCTestCase {
    /// Opt-in integration test: public fixture + existing model, never a live microphone.
    func testKnownSpeechFixtureAndCancelRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["AIR_WHISPER_TEST_MODEL"],
              let fixturePath = environment["AIR_WHISPER_TEST_WAV"] else {
            throw XCTSkip("Set AIR_WHISPER_TEST_MODEL and AIR_WHISPER_TEST_WAV for inference validation.")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixturePath))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let audio = CapturedAudio(samples: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
        let transcriber = WhisperTranscriber()
        try verifyVocabularyTokenBudget(modelURL: URL(fileURLWithPath: modelPath))
        try await transcriber.prepare(modelURL: URL(fileURLWithPath: modelPath))
        let text = try await transcriber.transcribe(audio, language: "en").lowercased()
        XCTAssertTrue(text.contains("fellow americans"), "The public speech fixture should match its known words.")
        XCTAssertTrue(text.contains("what you can do for your country"))
        let hinted = try await transcriber.transcribe(audio, language: "en", initialPrompt: "Americans, country").lowercased()
        XCTAssertTrue(hinted.contains("fellow americans"))
        XCTAssertTrue(hinted.contains("what you can do for your country"))
        let oversized = "Americans\u{0000}country\n" + String(repeating: "👩🏽‍💻", count: 1_000)
        let bounded = try await transcriber.transcribe(audio, language: "en", initialPrompt: oversized).lowercased()
        XCTAssertTrue(bounded.contains("fellow americans"), "Large, complex hints must remain valid C input.")
        let silent = try await transcriber.transcribe(CapturedAudio(samples: [Float](repeating: 0, count: 16_000)), language: "en", initialPrompt: "Americans, country")
        XCTAssertTrue(silent.isEmpty)
        let longAudio = CapturedAudio(samples: Array(repeating: audio.samples, count: 5).flatMap { $0 })
        let pending = Task { try await transcriber.transcribe(longAudio, language: "en", initialPrompt: "Americans, country") }
        try await Task.sleep(nanoseconds: 100_000_000)
        transcriber.cancel()
        do {
            _ = try await pending.value
            XCTFail("Expected the ongoing inference to be canceled.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await transcriber.transcribe(audio, language: "en").lowercased()
        XCTAssertTrue(recovered.contains("fellow americans"), "A canceled decode must not poison the retained context.")
        let obsoleteUnload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await transcriber.unload()
        }
        await obsoleteUnload.value
        let retainedSilence = try await transcriber.transcribe(CapturedAudio(samples: [Float](repeating: 0, count: 16_000)), language: "en")
        XCTAssertTrue(retainedSilence.isEmpty, "A canceled unload must preserve the current model context.")
        await transcriber.unload()
    }

    private func verifyVocabularyTokenBudget(modelURL: URL) throws {
        let manifest = try ModelValidator.identify(modelURL)
        try ModelValidator.validate(modelURL, manifest: manifest)
        var parameters = whisper_context_default_params()
        parameters.use_gpu = false
        // Tokenization only: no decoder state, inference or microphone is needed.
        let context = try XCTUnwrap(modelURL.path.withCString {
            whisper_init_from_file_with_params_no_state($0, parameters)
        })
        defer { whisper_free(context) }
        XCTAssertEqual(WhisperVocabulary.tokens(for: " , \n", context: context), [])
        XCTAssertEqual(WhisperVocabulary.tokens(for: "Ada\u{0000}Lovelace\ncountry", context: context),
                       WhisperVocabulary.tokens(for: "Ada Lovelace, country", context: context))
        let prefix = WhisperVocabulary.tokens(for: "Americans,", context: context)
        let long = WhisperVocabulary.tokens(for: "Americans, " + String(repeating: "👩🏽‍💻", count: 1_000), context: context)
        XCTAssertFalse(prefix.isEmpty)
        XCTAssertEqual(long.count, WhisperVocabulary.maximumTokens)
        XCTAssertEqual(Array(long.prefix(prefix.count)), prefix, "Keep the first terms when applying the actual token budget.")
    }

    func testCanceledUnloadCannotInvalidateNewerSession() async throws {
        let cancellation = InferenceCancellation()
        let transcriber = WhisperTranscriber(cancellation: cancellation)
        let newerSession = InferenceOperation(cancellation: cancellation, timeout: 60)
        let obsoleteUnload = Task {
            // Deterministically reproduce cancellation before actor entry, independent
            // of executor scheduling and without requiring a model or GPU.
            withUnsafeCurrentTask { $0?.cancel() }
            await transcriber.unload()
        }
        await obsoleteUnload.value
        XCTAssertNoThrow(try newerSession.check())
    }

    func testInvalidAudioNeverReachesC() throws {
        let invalid = [
            [Float](),
            [Float](repeating: 0, count: 1_599),
            [Float](repeating: .nan, count: 1_600),
            [Float](repeating: .infinity, count: 1_600),
            [Float](repeating: 2, count: 1_600),
            [Float](repeating: 0, count: 120 * 16_000 + 1),
        ]
        for samples in invalid {
            XCTAssertThrowsError(try WhisperInput.validate(CapturedAudio(samples: samples), language: "en"))
        }
        XCTAssertNoThrow(try WhisperInput.validate(CapturedAudio(samples: [Float](repeating: 0, count: 1_600)), language: "en"))
        XCTAssertThrowsError(try WhisperInput.validate(CapturedAudio(samples: [Float](repeating: 0, count: 1_600)), language: "fr"))
    }

    func testCancelDoesNotPoisonNextSession() throws {
        let cancellation = InferenceCancellation()
        let old = InferenceOperation(cancellation: cancellation, timeout: 60)
        cancellation.cancelAll()
        XCTAssertThrowsError(try old.check()) { XCTAssertTrue($0 is CancellationError) }
        let next = InferenceOperation(cancellation: cancellation, timeout: 60)
        old.cancel()
        XCTAssertNoThrow(try next.check())
        next.cancel()
        XCTAssertThrowsError(try next.check())
    }

    func testDeadlineIsEnforcedWithoutWaiting() {
        let operation = InferenceOperation(cancellation: InferenceCancellation(), timeout: -1)
        XCTAssertTrue(operation.shouldAbort)
        XCTAssertThrowsError(try operation.check()) {
            guard case SpeechError.timedOut = $0 else { return XCTFail("Expected deadline error") }
        }
    }

    func testModelHashDetectsCorruptionAfterValidHeaderAndSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.bin")
        let valid = ModelValidator.ggmlMagic + Data("test-model-contents".utf8)
        let manifest = ModelManifest(bytes: Int64(valid.count), sha256: digest(valid))
        try valid.write(to: url)
        XCTAssertNoThrow(try ModelValidator.validate(url, manifest: manifest))
        var corrupted = valid
        corrupted[corrupted.count - 1] ^= 0xff
        try corrupted.write(to: url)
        XCTAssertTrue(ModelValidator.appearsInstalled(url, manifest: manifest))
        XCTAssertThrowsError(try ModelValidator.validate(url, manifest: manifest))
        try valid.dropLast().write(to: url)
        XCTAssertFalse(ModelValidator.appearsInstalled(url, manifest: manifest))
    }

    func testModelValidationCanBeCanceledBeforeReading() throws {
        XCTAssertThrowsError(try ModelValidator.validate(URL(fileURLWithPath: "/nonexistent"),
            manifest: ModelManifest.forModel(.smallEnglish), checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    @MainActor func testPromotionAtomicallyReplacesPriorModelAndUsesPrivatePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("model.bin")
        let staging = directory.appendingPathComponent(".download")
        try Data("old".utf8).write(to: destination)
        try Data("verified-new".utf8).write(to: staging)
        try ModelManager.promote(staging, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("verified-new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor func testDiscoveryUsesLegacyModelWithoutWritingOrCreatingDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = directory.appendingPathComponent("new/models")
        let legacy = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let file = legacy.appendingPathComponent(SpeechModel.smallEnglish.fileName)
        FileManager.default.createFile(atPath: file.path, contents: ModelValidator.ggmlMagic)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ModelManifest.forModel(.smallEnglish).bytes))
        try handle.close()
        let manager = ModelManager(directory: models, legacyDirectory: legacy)
        XCTAssertEqual(manager.installedURL(for: .smallEnglish), file)
        XCTAssertNil(manager.installedURL(for: .mediumEnglish))
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCanceledDownloadNeverStartsNetworkRequest() async {
        let download = ModelDownload(url: URL(string: "https://invalid.invalid/model")!,
                                     stagingURL: URL(fileURLWithPath: "/nonexistent/model"), onProgress: { _ in })
        download.cancel()
        do {
            _ = try await download.start()
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTranscriptionBeforePrepareFailsWithoutInference() async {
        let transcriber = WhisperTranscriber()
        do {
            _ = try await transcriber.transcribe(CapturedAudio(samples: [Float](repeating: 0, count: 16_000)), language: "en")
            XCTFail("Expected unloaded model error")
        } catch {
            guard case SpeechError.modelNotLoaded = error else { return XCTFail("Expected unloaded model error") }
        }
        await transcriber.unload()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("air-whisper-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
