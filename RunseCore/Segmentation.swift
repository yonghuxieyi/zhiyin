import Foundation

/// Splits long text into translatable segments and detects the dominant
/// language of a passage. Pure functions, no I/O, covered by unit tests.
///
/// Rules: split on paragraph breaks first, then on sentence boundaries
/// (Chinese 。！？； and English . ! ?). Short pieces are merged up to
/// `maxChars` per segment so the model sees whole context; a single
/// sentence longer than `maxChars` is hard-split at the limit.
public enum TextSegmenter {
    /// Default segment ceiling. DeepSeek allows far more per call, but
    /// shorter segments translate more consistently and show progress.
    public static let defaultMaxChars = 800

    public static func segments(for text: String, maxChars: Int = defaultMaxChars) -> [String] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        for paragraph in paragraphs {
            result.append(contentsOf: segments(forParagraph: paragraph, maxChars: maxChars))
        }
        return result
    }

    private static func segments(forParagraph paragraph: String, maxChars: Int) -> [String] {
        let sentences = splitSentences(paragraph)
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for sentence in sentences {
            if sentence.count > maxChars {
                flush()
                var rest = sentence
                while rest.count > maxChars {
                    result.append(String(rest.prefix(maxChars)))
                    rest = String(rest.dropFirst(maxChars))
                }
                if !rest.isEmpty { result.append(rest) }
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= maxChars {
                current += sentence
            } else {
                flush()
                current = sentence
            }
        }
        flush()
        return result
    }

    /// Splits a paragraph into sentences, keeping each terminator with its
    /// sentence. Handles Chinese and English terminators, including closing
    /// quotes that follow a terminator.
    public static func splitSentences(_ paragraph: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", ";"]
        let closingQuotes: Set<Character> = ["”", "’", "\"", "』", "」"]
        var sentences: [String] = []
        var current = ""
        let characters = Array(paragraph)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            current.append(char)
            if terminators.contains(char) {
                // Attach trailing closing quotes to the same sentence.
                var next = index + 1
                while next < characters.count && closingQuotes.contains(characters[next]) {
                    current.append(characters[next])
                    next += 1
                }
                index = next
                sentences.append(current)
                current = ""
                continue
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current)
        }
        return sentences
    }
}

/// Dominant language of a passage, decided by the share of CJK characters.
/// Used to pick the translation direction (Chinese -> English or
/// English -> Chinese) for voice and photo input.
public enum TextLanguage: String, Sendable {
    case chinese
    case english

    public static func detect(_ text: String) -> TextLanguage {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return .english }
        let cjkCount = letters.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }.count
        return Double(cjkCount) / Double(letters.count) >= 0.3 ? .chinese : .english
    }

    /// The language a passage in this language should be translated to.
    public var translationTarget: String {
        switch self {
        case .chinese: "English"
        case .english: "中文"
        }
    }
}
