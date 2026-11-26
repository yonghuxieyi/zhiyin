import Foundation

/// Splits long text into translatable segments and detects the dominant
/// language of a passage. Pure functions, no I/O, covered by unit tests.
///
/// Rules: split on paragraph breaks first, then on sentence boundaries
/// (Chinese 。！？； and English . ! ?). Short pieces are merged up to
/// `maxChars` per segment so the model sees whole context; a single
/// sentence longer than `maxChars` is hard-split at the limit.
///
/// Blank lines are preserved as empty-string segments so the translated
/// text keeps the original paragraph spacing when callers join the
/// segments with "\n" (the pipeline passes empty segments through
/// without calling the provider).
public enum TextSegmenter {
    /// Default segment ceiling. DeepSeek allows far more per call, but
    /// shorter segments translate more consistently and show progress.
    public static let defaultMaxChars = 800

    /// Segment ceiling for a provider: Qwen-MT caps output at 8K tokens,
    /// so its segments are capped at 1500 chars — clearly below the cap
    /// even when the translation expands. Everything else uses the
    /// default 800.
    public static func maxChars(for profile: ProviderProfile) -> Int {
        profile.isQwenMT ? QwenMT.maxSegmentChars : defaultMaxChars
    }

    public static func segments(for text: String, maxChars: Int = defaultMaxChars) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var pendingBlank = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // Collapse runs of blank lines into one empty segment.
                pendingBlank = true
                continue
            }
            if pendingBlank, !result.isEmpty {
                result.append("")
                pendingBlank = false
            }
            pendingBlank = false
            result.append(contentsOf: segments(forParagraph: line, maxChars: maxChars))
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
    ///
    /// A "." is NOT a sentence end when it is part of a decimal
    /// ("3.14"), a version number ("1.2.3"), a domain or URL
    /// ("example.com", "www.foo.bar"), or a known abbreviation
    /// ("U.S.", "Mr.", "e.g.", "a.m.") — those would otherwise be
    /// chopped into nonsense pieces.
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
            if terminators.contains(char), isSentenceEnd(characters, at: index) {
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

    /// Decides whether the terminator at `index` ends a sentence.
    /// Only "." needs the extra checks; every other terminator
    /// always ends the sentence.
    private static func isSentenceEnd(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "." else { return true }
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        let prev = index > 0 ? characters[index - 1] : nil
        // Decimal / version: digit on both sides ("3.14", "1.2.3").
        if let prev, let next, prev.isNumber, next.isNumber { return false }
        // Domain / URL / abbreviation mid-word: a letter follows the
        // dot with no space ("example.com", "U.S.A").
        if let next, next.isLetter { return false }
        // Known abbreviation immediately before the dot ("Mr.", "e.g.",
        // "U.S.", "a.m."): look back at the word ending here.
        if isAbbreviation(characters, endingAt: index) { return false }
        return true
    }

    /// True when the word ending at the "." at `dotIndex` is a known
    /// abbreviation (compared case-insensitively, dots stripped).
    private static func isAbbreviation(_ characters: [Character], endingAt dotIndex: Int) -> Bool {
        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "st", "vs", "etc", "eg", "ie",
            "am", "pm", "us", "usa", "uk", "jr", "sr", "prof", "no",
            "approx", "fig", "eq", "al"
        ]
        var start = dotIndex - 1
        while start >= 0, characters[start].isLetter || characters[start] == "." {
            start -= 1
        }
        let word = String(characters[(start + 1)..<dotIndex])
            .replacingOccurrences(of: ".", with: "")
            .lowercased()
        return abbreviations.contains(word)
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
