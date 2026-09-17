import Foundation

enum AppVersion {
    private static let versionAndBuild: String? = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuild = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty, !trimmedBuild.isEmpty else { return nil }
        return "\(trimmedVersion) (\(trimmedBuild))"
    }()

    static var appTitle: String {
        versionAndBuild.map { "Air Whisper \($0)" } ?? "Air Whisper (development build)"
    }

    static var detail: String {
        versionAndBuild.map { "Version \($0)" } ?? "Development build — version unavailable"
    }
}
