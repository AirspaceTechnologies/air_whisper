import AppKit
import AVFoundation
import AirWhisperCore
import AirWhisperSpeech

@main
enum AirWhisperMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--self-check") {
            // This path deliberately avoids controller, audio-device discovery, settings,
            // microphone authorization, event taps, model downloads, and the app loop.
            guard PushToTalkKey.fn.keyCode == 63,
                  TextCleaner.clean("Hello world.") == "Hello world." else {
                fputs("Air Whisper self-check failed.\n", stderr)
                exit(1)
            }
            print("Air Whisper self-check passed (native executable; no microphone or permission requests).")
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("AirWhisper [--self-check | --transcribe-file PATH --model MODEL_PATH [--expect-text TEXT]]")
            print("The file check reports success and transcript length only; it does not print speech content.")
            return
        }
        if let index = arguments.firstIndex(of: "--transcribe-file") {
            guard index + 1 < arguments.count, let modelIndex = arguments.firstIndex(of: "--model"), modelIndex + 1 < arguments.count else {
                fputs("Usage: AirWhisper --transcribe-file PATH --model MODEL_PATH\n", stderr)
                exit(2)
            }
            do {
                let audio = try FileAudioDecoder.decode(URL(fileURLWithPath: arguments[index + 1]))
                let transcriber = WhisperTranscriber()
                try await transcriber.prepare(modelURL: URL(fileURLWithPath: arguments[modelIndex + 1]))
                let text = try await transcriber.transcribe(audio, language: "en")
                let cleaned = TextCleaner.clean(text)
                await transcriber.unload()
                guard let cleaned, !cleaned.isEmpty else { throw FileAudioDecoder.Failure("No speech was recognized in the fixture.") }
                if let expectedIndex = arguments.firstIndex(of: "--expect-text") {
                    guard expectedIndex + 1 < arguments.count else {
                        throw FileAudioDecoder.Failure("--expect-text requires a nonempty phrase.")
                    }
                    guard FixtureAssertion.contains(cleaned, expected: arguments[expectedIndex + 1]) else {
                        throw FileAudioDecoder.Failure("Fixture transcription did not contain the expected phrase.")
                    }
                }
                print("File transcription passed: \(String(format: "%.2f", audio.duration)) seconds, \(cleaned.count) characters. No transcript was logged.")
            } catch {
                fputs("File transcription failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if !arguments.isEmpty && !arguments.allSatisfy({ $0.hasPrefix("-psn_") }) {
            fputs("Unknown arguments. Use --help for diagnostic options.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum FixtureAssertion {
    static func contains(_ transcript: String, expected: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let phrase = normalized(expected)
        return !phrase.isEmpty && normalized(transcript).contains(phrase)
    }
}

enum FileAudioDecoder {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    static func decode(_ url: URL) throws -> CapturedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0,
              Double(file.length) / format.sampleRate <= 120,
              file.length <= Int64(UInt32.max),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw Failure("The fixture must be a readable audio file no longer than 120 seconds.")
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure("Could not allocate the audio conversion buffer.")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard result != .error, let samples = output.floatChannelData?[0], output.frameLength > 0 else {
            throw Failure("Could not convert the fixture to mono audio.")
        }
        return CapturedAudio(samples: Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
    }
}
