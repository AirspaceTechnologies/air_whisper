import AirWhisperCore
import CryptoKit
import Foundation
import XCTest
@testable import AirWhisperLLM

final class LLMTests: XCTestCase {
    func testCleanupModelHashDetectsCorruptionAfterValidHeaderAndSize() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.gguf")
        let valid = LLMModelValidator.ggufMagic + Data("test-model-contents".utf8)
        let manifest = LLMModelManifest(bytes: Int64(valid.count), sha256: digest(valid))
        try valid.write(to: url)
        XCTAssertNoThrow(try LLMModelValidator.validate(url, manifest: manifest))
        var corrupted = valid
        corrupted[corrupted.count - 1] ^= 0xff
        try corrupted.write(to: url)
        XCTAssertTrue(LLMModelValidator.appearsInstalled(url, manifest: manifest))
        XCTAssertThrowsError(try LLMModelValidator.validate(url, manifest: manifest))
    }

    func testUnsupportedFileIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-a-model.bin")
        try Data("not a gguf file".utf8).write(to: url)
        XCTAssertThrowsError(try LLMModelValidator.identify(url)) {
            guard case LLMError.unsupportedModel = $0 else { return XCTFail("Expected unsupportedModel") }
        }
    }

    func testEmptyTranscriptSkipsInferenceEntirely() async throws {
        let cleaner = TranscriptCleaner()
        let result = try await cleaner.cleanup("")
        XCTAssertEqual(result, "")
    }

    @MainActor func testDiscoveryDoesNotCreateDirectories() throws {
        let directory = try temporaryDirectory().appendingPathComponent("models")
        let manager = LLMModelManager(directory: directory)
        XCTAssertNil(manager.installedURL(for: .qwen2_5_1_5bInstruct))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        var hash = SHA256()
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
