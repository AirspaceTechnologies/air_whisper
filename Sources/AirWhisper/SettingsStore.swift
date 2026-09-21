import Foundation
import AirWhisperCore

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: DictationSettings {
        didSet { persist() }
    }
    @Published private(set) var modelPaths: [String: String]
    private let defaults: UserDefaults
    private static let settingsKey = "dictationSettings.v1"
    private static let modelsKey = "selectedModelPaths.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(DictationSettings.self, from: data) {
            value = Self.validated(decoded)
        } else {
            value = DictationSettings()
        }
        modelPaths = defaults.dictionary(forKey: Self.modelsKey) as? [String: String] ?? [:]
    }

    static func validated(_ settings: DictationSettings) -> DictationSettings {
        var value = settings
        value.minimumDuration = settings.minimumDuration.isFinite ? min(5, max(0.2, settings.minimumDuration)) : 0.5
        value.maximumDuration = settings.maximumDuration.isFinite ? min(120, max(5, settings.maximumDuration)) : 120
        value.restoreDelay = settings.restoreDelay.isFinite ? min(5, max(0.1, settings.restoreDelay)) : 0.3
        value.vocabulary = VocabularyPrompt.sanitize(settings.vocabulary)
        return value
    }

    func modelURL(for model: SpeechModel) -> URL? {
        guard let path = modelPaths[model.rawValue],
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func useModel(at url: URL, for model: SpeechModel) {
        modelPaths[model.rawValue] = url.path
        defaults.set(modelPaths, forKey: Self.modelsKey)
    }

    func clearModelOverride(for model: SpeechModel) {
        modelPaths.removeValue(forKey: model.rawValue)
        defaults.set(modelPaths, forKey: Self.modelsKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Self.validated(value)) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}
