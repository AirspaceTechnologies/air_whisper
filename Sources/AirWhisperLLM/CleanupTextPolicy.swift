import Foundation

/// Model text is untrusted. Cleanup may alter punctuation/case or omit hesitation
/// sounds, but cannot add, reorder, or remove substantive words. This conservative
/// check intentionally rejects some useful rewrites rather than silently losing speech.
enum CleanupTextPolicy {
    static let maximumInputBytes = 12_000
    private static let hesitations: Set<String> = ["um", "uh", "umm", "uhh"]

    static func userMessage(_ transcript: String) throws -> String {
        guard transcript.utf8.count <= maximumInputBytes,
              !transcript.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw LLMError.transcriptTooLong
        }
        let data = try JSONEncoder().encode(["transcript": transcript])
        // Escape chat-template markers as JSON data before special-token parsing.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
    }

    static func validate(_ candidate: String, original: String) throws -> String {
        let output = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty,
              output.utf8.count <= maximumInputBytes * 2,
              !output.contains("\u{fffd}"),
              !output.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw LLMError.unsafeOutput
        }
        let inputWords = words(original).filter { !hesitations.contains($0) }
        let outputWords = words(output).filter { !hesitations.contains($0) }
        guard !inputWords.isEmpty, inputWords == outputWords,
              protectedLiterals(original) == protectedLiterals(output) else { throw LLMError.unsafeOutput }
        return output
    }

    // Alphanumeric equality alone misses a lost minus sign, decimal separator,
    // currency/percent symbol, or address punctuation. Preserve these literals too.
    private static let literalPattern = try! NSRegularExpression(
        pattern: #"(?:https?://|www\.)[^\s]+|[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}|(?:[\p{Sc}\p{Sm}\-−]\s*)*\p{N}+(?:[.,:/\-]\p{N}+)*(?:\s*[%‰\p{Sc}])?|[<>=≤≥≠]"#,
        options: [.caseInsensitive]
    )

    private static func protectedLiterals(_ text: String) -> [String] {
        literalPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).components(separatedBy: .whitespacesAndNewlines).joined()
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
