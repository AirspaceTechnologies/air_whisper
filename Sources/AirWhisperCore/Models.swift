import Foundation

public enum PushToTalkKey: String, CaseIterable, Codable, Sendable {
    case fn, rightalt, rightcmd, rightctrl

    public var title: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightalt: return "Right Option"
        case .rightcmd: return "Right Command"
        case .rightctrl: return "Right Control"
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightalt: return 61
        case .rightcmd: return 54
        case .rightctrl: return 62
        }
    }

    public var rawMask: UInt64 {
        switch self {
        case .fn: return 0x800000
        case .rightalt: return 0x40
        case .rightcmd: return 0x10
        case .rightctrl: return 0x2000
        }
    }
}

public enum PasteMode: String, CaseIterable, Codable, Sendable {
    case clipboard, keystrokes
}

public enum MicrophoneMode: String, CaseIterable, Codable, Sendable {
    case auto, fixed
}

public enum SpeechModel: String, CaseIterable, Codable, Sendable {
    case smallEnglish, mediumEnglish

    public var title: String { self == .smallEnglish ? "Small English" : "Medium English" }
    public var fileName: String { self == .smallEnglish ? "ggml-small.en.bin" : "ggml-medium.en.bin" }
    public var minimumBytes: Int64 { self == .smallEnglish ? 450_000_000 : 1_400_000_000 }
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/\(fileName)")!
    }
}

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let isBluetooth: Bool
    public let isBuiltIn: Bool

    public init(id: String, name: String, isDefault: Bool = false, isBluetooth: Bool = false, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.isBluetooth = isBluetooth
        self.isBuiltIn = isBuiltIn
    }
}

/// Owned mono PCM samples at 16 kHz. Audio never needs an application-created file.
public struct CapturedAudio: Sendable {
    public let samples: [Float]
    public static let sampleRate = 16_000
    public var duration: TimeInterval { Double(samples.count) / Double(Self.sampleRate) }

    public init(samples: [Float]) { self.samples = samples }
}

public struct DictationSettings: Codable, Equatable, Sendable {
    public var hotkey: PushToTalkKey = .fn
    public var pasteMode: PasteMode = .clipboard
    public var microphoneMode: MicrophoneMode = .auto
    public var fixedDeviceID: String?
    public var screenMicrophones: [String: String] = [:]
    public var model: SpeechModel = .smallEnglish
    public var minimumDuration: TimeInterval = 0.5
    public var maximumDuration: TimeInterval = 120
    public var restoreDelay: TimeInterval = 0.3
    public var vocabulary: String = ""

    public init() {}
}

public enum VocabularyPrompt {
    /// whisper.cpp's initial_prompt shares the model's limited context window with the
    /// audio itself. Keep the glossary short so it cannot crowd out the actual speech.
    public static let maximumLength = 400

    public static func sanitize(_ raw: String) -> String {
        let flattened = raw
            .components(separatedBy: .newlines)
            .joined(separator: ", ")
            .trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(maximumLength))
    }
}
