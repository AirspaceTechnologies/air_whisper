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

    private enum CodingKeys: String, CodingKey {
        case hotkey, pasteMode, microphoneMode, fixedDeviceID, screenMicrophones, model
        case minimumDuration, maximumDuration, restoreDelay, vocabulary
    }

    public init(from decoder: Decoder) throws {
        // Older installations have no vocabulary key. Preserve their selected key,
        // microphone, model and timings when new optional preferences are added.
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try values.decodeIfPresent(PushToTalkKey.self, forKey: .hotkey) ?? hotkey
        pasteMode = try values.decodeIfPresent(PasteMode.self, forKey: .pasteMode) ?? pasteMode
        microphoneMode = try values.decodeIfPresent(MicrophoneMode.self, forKey: .microphoneMode) ?? microphoneMode
        fixedDeviceID = try values.decodeIfPresent(String.self, forKey: .fixedDeviceID)
        screenMicrophones = try values.decodeIfPresent([String: String].self, forKey: .screenMicrophones) ?? screenMicrophones
        model = try values.decodeIfPresent(SpeechModel.self, forKey: .model) ?? model
        minimumDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .minimumDuration) ?? minimumDuration
        maximumDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .maximumDuration) ?? maximumDuration
        restoreDelay = try values.decodeIfPresent(TimeInterval.self, forKey: .restoreDelay) ?? restoreDelay
        vocabulary = try values.decodeIfPresent(String.self, forKey: .vocabulary) ?? ""
    }
}

public enum VocabularyPrompt {
    /// A UI limit; the speech layer also enforces the decoder's token budget.
    public static let maximumLength = 400
    public static let maximumUTF8Bytes = 1_600

    public static func sanitize(_ raw: String) -> String {
        // Bound work before counting grapheme clusters: a single apparent character
        // can contain arbitrarily many combining marks. Never pass embedded NULs or
        // other control characters into a C string.
        var bounded = ""
        var bytes = 0
        for scalar in raw.unicodeScalars {
            let piece: String
            if CharacterSet.newlines.contains(scalar) {
                piece = ","
            } else if scalar.properties.generalCategory == .control {
                piece = " "
            } else {
                piece = String(scalar)
            }
            guard bytes + piece.utf8.count <= maximumUTF8Bytes else { break }
            bounded += piece
            bytes += piece.utf8.count
        }
        let flattened = bounded.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        var result = ""
        for character in flattened.prefix(maximumLength) {
            guard result.utf8.count + character.utf8.count <= maximumUTF8Bytes else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
    }
}
