import AirWhisperCore
import Foundation
import Metal
import whisper

/// A cancel generation prevents an old operation from canceling a subsequent session.
final class InferenceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }
}

final class InferenceOperation: @unchecked Sendable {
    private let cancellation: InferenceCancellation
    private let generation: UInt64
    private let lock = NSLock()
    private var canceled = false
    private let deadline: TimeInterval

    init(cancellation: InferenceCancellation, timeout: TimeInterval) {
        self.cancellation = cancellation
        generation = cancellation.snapshot()
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        canceled = true
    }

    func check() throws {
        lock.lock()
        let localCancellation = canceled
        lock.unlock()
        if localCancellation || generation != cancellation.snapshot() { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw SpeechError.timedOut }
    }

    var shouldAbort: Bool {
        do { try check(); return false } catch { return true }
    }
}

private let whisperAbort: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { raw in
    guard let raw else { return true }
    return Unmanaged<InferenceOperation>.fromOpaque(raw).takeUnretainedValue().shouldAbort
}

enum WhisperInput {
    static func validate(_ audio: CapturedAudio, language: String) throws {
        guard audio.samples.count >= CapturedAudio.sampleRate / 10,
              audio.duration <= 120,
              audio.samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw SpeechError.invalidAudio }
        guard language == "en" || language == "english" else { throw SpeechError.unsupportedLanguage }
    }
}

enum WhisperVocabulary {
    // Keep headroom for recognized speech in the 448-token English decoder. The
    // framework otherwise silently keeps the end of an oversized initial prompt.
    static let maximumTokens = 128

    static func tokens(for raw: String, context: OpaquePointer) -> [whisper_token] {
        let prompt = VocabularyPrompt.sanitize(raw)
        guard !prompt.isEmpty else { return [] }
        // Byte-pair tokenization cannot produce more tokens than UTF-8 bytes.
        var tokens = [whisper_token](repeating: 0, count: prompt.utf8.count)
        let count = prompt.withCString { text in
            tokens.withUnsafeMutableBufferPointer {
                whisper_tokenize(context, text, $0.baseAddress, Int32($0.count))
            }
        }
        guard count > 0, count <= tokens.count else { return [] }
        let limit = max(0, min(maximumTokens, Int(whisper_n_text_ctx(context)) / 2 - 1))
        return Array(tokens.prefix(min(Int(count), limit)))
    }
}

/// Every access to the C context occurs on this serial queue, including destruction.
private final class WhisperWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.airwhisper.inference", qos: .userInitiated)
    private var context: OpaquePointer?
    private var modelURL: URL?

    // whisper and ggml's log callbacks are global. Initialize once before any model loads.
    private static let silenceLibraryLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
        ggml_log_set({ _, _, _ in }, nil)
    }()

    init() { _ = Self.silenceLibraryLogs }

    deinit {
        // Queued work retains the worker. Release on its queue even if the actor's final
        // reference goes away on main. Transfer pointer ownership exactly once.
        if let context {
            let address = UInt(bitPattern: context)
            queue.async { whisper_free(OpaquePointer(bitPattern: address)) }
        }
    }

    func prepare(modelURL: URL, operation: InferenceOperation) throws {
        try operation.check()
        let url = modelURL.standardizedFileURL
        if self.modelURL == url, context != nil { return }
        let manifest = try ModelValidator.identify(url)
        try ModelValidator.validate(url, manifest: manifest, checkCancellation: operation.check)
        // Free the old context before allocating another model's multi-GB working set.
        unload()
        var parameters = whisper_context_default_params()
        // A device can exist even when a host sandbox denies GPU allocations. Some
        // upstream Metal paths assume allocations succeed; probe access before loading.
        if let device = MTLCreateSystemDefaultDevice(),
           device.makeBuffer(length: 4_096, options: .storageModePrivate) != nil,
           device.makeBuffer(length: 4_096, options: .storageModeShared) != nil {
            parameters.use_gpu = true
        } else {
            parameters.use_gpu = false
        }
        parameters.flash_attn = true
        guard let loaded = url.path.withCString({ whisper_init_from_file_with_params($0, parameters) }) else {
            throw SpeechError.modelLoadFailed
        }
        do { try operation.check() } catch {
            whisper_free(loaded)
            throw error
        }
        context = loaded
        self.modelURL = url
    }

    func transcribe(_ audio: CapturedAudio, language: String, initialPrompt: String, operation: InferenceOperation) throws -> String {
        try operation.check()
        try WhisperInput.validate(audio, language: language)
        guard let context else { throw SpeechError.modelNotLoaded }
        // Digital silence cannot contain speech. Skip decoding to prevent silence hallucinations.
        guard audio.samples.contains(where: { abs($0) > 0.0000001 }) else { return "" }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        parameters.translate = false
        parameters.no_context = true
        parameters.no_timestamps = true
        parameters.single_segment = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.suppress_blank = true
        parameters.suppress_nst = true
        parameters.temperature = 0
        parameters.temperature_inc = 0
        parameters.greedy.best_of = 1
        parameters.abort_callback = whisperAbort
        parameters.abort_callback_user_data = Unmanaged.passUnretained(operation).toOpaque()
        parameters.encoder_begin_callback = { _, _, raw in !whisperAbort(raw) }
        parameters.encoder_begin_callback_user_data = parameters.abort_callback_user_data

        let promptTokens = WhisperVocabulary.tokens(for: initialPrompt, context: context)
        try operation.check()
        let result: Int32 = "en".withCString { languagePointer in
            parameters.language = languagePointer
            return promptTokens.withUnsafeBufferPointer { prompt -> Int32 in
                parameters.prompt_tokens = prompt.isEmpty ? nil : prompt.baseAddress
                parameters.prompt_n_tokens = Int32(prompt.count)
                return audio.samples.withUnsafeBufferPointer { samples in
                    whisper_full(context, parameters, samples.baseAddress, Int32(samples.count))
                }
            }
        }
        try operation.check()
        guard result == 0 else { throw SpeechError.inferenceFailed(result) }
        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        if let context { whisper_free(context) }
        context = nil
        modelURL = nil
    }
}

public actor WhisperTranscriber {
    private let worker = WhisperWorker()
    private nonisolated let cancellation: InferenceCancellation

    public init() { cancellation = InferenceCancellation() }

    init(cancellation: InferenceCancellation) { self.cancellation = cancellation }

    public func prepare(modelURL: URL) async throws {
        try Task.checkCancellation()
        let operation = InferenceOperation(cancellation: cancellation, timeout: 180)
        try await perform(operation: operation) { worker in
            try worker.prepare(modelURL: modelURL, operation: operation)
        }
    }

    public func transcribe(_ audio: CapturedAudio, language: String, initialPrompt: String = "") async throws -> String {
        try Task.checkCancellation()
        let operation = InferenceOperation(cancellation: cancellation, timeout: max(30, min(180, audio.duration * 3)))
        return try await perform(operation: operation) { worker in
            try worker.transcribe(audio, language: language, initialPrompt: initialPrompt, operation: operation)
        }
    }

    public nonisolated func cancel() { cancellation.cancelAll() }

    public func unload() async {
        // A canceled model-selection task can reach this actor after a newer prepare.
        // It must not invalidate that newer operation's generation or free its context.
        guard !Task.isCancelled else { return }
        cancel()
        let operation = InferenceOperation(cancellation: cancellation, timeout: .infinity)
        let worker = self.worker
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.queue.async {
                    // A queued unload may be canceled while earlier C work drains.
                    // All context operations share this queue, preserving their order.
                    if !operation.shouldAbort { worker.unload() }
                    continuation.resume()
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func perform<T>(operation: InferenceOperation, body: @escaping @Sendable (WhisperWorker) throws -> T) async throws -> T {
        let worker = self.worker
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.queue.async {
                    do {
                        try operation.check()
                        continuation.resume(returning: try body(worker))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
