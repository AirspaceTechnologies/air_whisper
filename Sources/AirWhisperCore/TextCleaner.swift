import Foundation

public enum TextCleaner {
    public static func clean(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines).filter {
            $0.range(of: #"^\s*(?:\[[^\]]*\]|\([^)]*\))[\s\p{P}]*$"#, options: .regularExpression) == nil
        }
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\[BLANK_AUDIO\]|\[Music\]|\(silence\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        // Unicode letters are boundaries too: do not alter words containing a filler.
        text = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}_])(?:um|uhm|uh|er|ah|hmm)(?![\p{L}\p{N}_]),?"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return nil }
        text = first.uppercased() + text.dropFirst()
        let blocklist: Set<String> = ["thank you.", "thanks for watching.", "you", "thank you for watching."]
        return blocklist.contains(text.lowercased()) ? nil : text
    }
}
