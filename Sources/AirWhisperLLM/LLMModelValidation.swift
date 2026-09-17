import AirWhisperCore
import CryptoKit
import Foundation

public enum LLMError: LocalizedError {
    case unsupportedModel
    case invalidModel
    case modelNotLoaded
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case unsafeOutput
    case transcriptTooLong
    case inferenceFailed
    case timedOut
    case downloadInProgress
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel: return "Choose the supported official Qwen2.5 1.5B Instruct Q4_K_M GGUF model."
        case .invalidModel: return "The cleanup model is incomplete or failed its SHA256 check. Download it again."
        case .modelNotLoaded: return "Choose and prepare a cleanup model before enabling AI cleanup."
        case .modelLoadFailed: return "The cleanup model could not be loaded. Free some memory and try again."
        case .contextCreationFailed: return "The cleanup model's context could not be created."
        case .tokenizationFailed: return "The transcript could not be tokenized for cleanup."
        case .unsafeOutput: return "Cleanup changed or omitted words. The original transcript was used instead."
        case .transcriptTooLong: return "This transcript exceeds the cleanup limit. The original transcript was used instead."
        case .inferenceFailed: return "Transcript cleanup failed. The original transcript was used instead."
        case .timedOut: return "Transcript cleanup took too long and was canceled."
        case .downloadInProgress: return "A cleanup model download is already running."
        case .downloadFailed: return "The cleanup model could not be downloaded. Check your connection and try again."
        }
    }
}

/// Pinned to Qwen/Qwen2.5-1.5B-Instruct-GGUF revision 91cad51170dc346986eccefdc2dd33a9da36ead9.
/// The hash is the official Hugging Face LFS SHA256 object identifier.
struct LLMModelManifest: Sendable {
    let bytes: Int64
    let sha256: String

    static func forModel(_ model: CleanupModel) -> Self {
        switch model {
        case .qwen2_5_1_5bInstruct:
            return Self(bytes: 1_117_320_736, sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")
        }
    }
}

enum LLMModelValidator {
    static let ggufMagic = Data([0x47, 0x47, 0x55, 0x46])

    /// Cheap discovery only. Full validation always happens off main before C inference.
    static func appearsInstalled(_ url: URL, manifest: LLMModelManifest) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(file.fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == manifest.bytes else { return false }
        return (try? file.read(upToCount: 4)) == ggufMagic
    }

    static func identify(_ url: URL) throws -> LLMModelManifest {
        for model in CleanupModel.allCases {
            let manifest = LLMModelManifest.forModel(model)
            if appearsInstalled(url, manifest: manifest) { return manifest }
        }
        throw LLMError.unsupportedModel
    }

    static func validate(_ url: URL, manifest: LLMModelManifest, checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        guard appearsInstalled(url, manifest: manifest) else { throw LLMError.invalidModel }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try checkCancellation()
            count += Int64(data.count)
            guard count <= manifest.bytes else { throw LLMError.invalidModel }
            hash.update(data: data)
        }
        try checkCancellation()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == manifest.bytes, digest == manifest.sha256 else { throw LLMError.invalidModel }
    }
}
