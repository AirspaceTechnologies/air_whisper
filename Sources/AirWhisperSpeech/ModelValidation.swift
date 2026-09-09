import AirWhisperCore
import CryptoKit
import Darwin
import Foundation

public enum SpeechError: LocalizedError {
    case invalidModel
    case unsupportedModel
    case modelNotLoaded
    case modelLoadFailed
    case invalidAudio
    case unsupportedLanguage
    case inferenceFailed(Int32)
    case timedOut
    case downloadInProgress
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidModel: return "The model is incomplete or failed its SHA256 check. Download it again."
        case .unsupportedModel: return "Choose an official, unquantized ggml-small.en.bin or ggml-medium.en.bin model."
        case .modelNotLoaded: return "Choose and prepare a speech model before dictating."
        case .modelLoadFailed: return "The speech model could not be loaded. Try the smaller model or free some memory."
        case .invalidAudio: return "The recording is empty, too short, too long, or contains invalid audio samples."
        case .unsupportedLanguage: return "The bundled model choices support English. Select English for transcription."
        case .inferenceFailed: return "Transcription failed. Try recording again."
        case .timedOut: return "Transcription took too long and was canceled. Try a shorter recording."
        case .downloadInProgress: return "A model download is already running."
        case .downloadFailed: return "The model could not be downloaded. Check your connection and try again."
        }
    }
}

/// Pinned to ggerganov/whisper.cpp revision 5359861c739e955e79d9a303bcbc70fb988958b1.
/// Hashes are the official Hugging Face LFS SHA256 object identifiers.
struct ModelManifest: Sendable {
    let bytes: Int64
    let sha256: String

    static func forModel(_ model: SpeechModel) -> Self {
        switch model {
        case .smallEnglish:
            return Self(bytes: 487_614_201, sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d")
        case .mediumEnglish:
            return Self(bytes: 1_533_774_781, sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356")
        }
    }
}

enum ModelValidator {
    static let ggmlMagic = Data([0x6c, 0x6d, 0x67, 0x67])

    /// Cheap discovery only. Full validation always happens off main before C inference.
    static func appearsInstalled(_ url: URL, manifest: ModelManifest) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        // URL resource values may cache a stale size after a file is replaced/truncated.
        // Inspect the actual open descriptor instead.
        var metadata = stat()
        guard fstat(file.fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == manifest.bytes else { return false }
        return (try? file.read(upToCount: 4)) == ggmlMagic
    }

    static func identify(_ url: URL) throws -> ModelManifest {
        for model in SpeechModel.allCases {
            let manifest = ModelManifest.forModel(model)
            if appearsInstalled(url, manifest: manifest) { return manifest }
        }
        throw SpeechError.unsupportedModel
    }

    static func validate(_ url: URL, manifest: ModelManifest, checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        guard appearsInstalled(url, manifest: manifest) else { throw SpeechError.invalidModel }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try checkCancellation()
            count += Int64(data.count)
            guard count <= manifest.bytes else { throw SpeechError.invalidModel }
            hash.update(data: data)
        }
        try checkCancellation()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == manifest.bytes, digest == manifest.sha256 else { throw SpeechError.invalidModel }
    }
}
