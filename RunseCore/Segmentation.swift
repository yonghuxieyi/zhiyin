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
    /// ("example.com", "www.foo.bar"), an ellipsis ("..."), a
    /// single-letter initial ("J. Smith"), or an abbreviation that
    /// almost always sits mid-sentence ("U.S. Government", "vs.
    /// Tyson", "e.g. Fuji", "Ph.D. in physics"). "a.m." / "p.m." /
    /// "etc." do end a sentence when followed by a space and a
    /// capital letter — "at 9 a.m. He was early." splits after
    /// "a.m." — unless the next word continues the time ("9 a.m.
    /// Eastern Time" stays together).
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
        // C4: ellipsis — a dot next to another dot belongs to "..."
        // ("He paused... then continued.") and never ends a sentence
        // on its own.
        if prev == "." || next == "." { return false }
        // C3: single-letter initial ("J. Smith"): one letter with no
        // dot before it is a name initial, not a sentence end.
        if isSingleInitial(characters, endingAt: index) { return false }
        // Known abbreviation immediately before the dot ("Mr.", "e.g.",
        // "U.S.", "a.m."): look back at the word ending here.
        if let abbreviation = abbreviationEndingAt(characters, endingAt: index) {
            // C1/C2: these abbreviations essentially never end a
            // sentence — "U.S. Government", "vs. Tyson", "e.g. Fuji",
            // "Ph.D. in physics" are all mid-sentence, and splitting
            // after them produced fragments that mistranslate.
            if Self.neverSplitAbbreviations.contains(abbreviation) { return false }
            // Titles ("Mr.", "Dr.") never end a sentence, so they never
            // split.
            if Self.titleAbbreviations.contains(abbreviation) { return false }
            // "a.m." / "p.m." / "etc." CAN end one: "at 9 a.m. He was
            // early." splits after "a.m.", while "Mr. Smith" does not
            // split after "Mr.". The tell is what follows: a space and
            // a capital letter (or the end of the text) means the
            // abbreviation closed the sentence — unless the next word
            // continues the time ("9 a.m. Eastern Time", "3 p.m.
            // Monday" stay together).
            var nextIndex = index + 1
            while nextIndex < characters.count, characters[nextIndex] == " " {
                nextIndex += 1
            }
            if nextIndex >= characters.count { return true }
            if (abbreviation == "am" || abbreviation == "pm"),
               let nextWord = wordStartingAt(characters, from: nextIndex),
               Self.timeContinuationWords.contains(nextWord) { return false }
            return characters[nextIndex].isUppercase
        }
        return true
    }

    /// Abbreviations that never end a sentence: titles and honorifics
    /// are always followed by a name ("Mr. Smith", "Dr. Lee").
    private static let titleAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "prof", "jr", "sr", "no"
    ]

    /// Abbreviations that essentially never end a sentence: they sit
    /// mid-sentence far more often than at the end ("U.S.
    /// Government", "X vs. Tyson", "e.g. Fuji", "a Ph.D. in
    /// physics"). Missing a split here only makes a segment longer;
    /// a wrong split fragments the sentence and mistranslates it.
    private static let neverSplitAbbreviations: Set<String> = [
        "vs", "eg", "ie", "us", "usa", "uk", "phd", "md", "edd", "dphil"
    ]

    /// Words that continue a time expression after "a.m." / "p.m."
    /// instead of starting a new sentence ("9 a.m. Eastern Time",
    /// "3 p.m. Monday").
    private static let timeContinuationWords: Set<String> = [
        "eastern", "pacific", "central", "mountain",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "today", "tomorrow", "yesterday"
    ]

    /// True when the word ending at the "." at `dotIndex` is a single
    /// letter standing on its own — a name initial ("J. Smith"). A
    /// letter preceded by a dot ("a.m.", "U.S.") is part of a dotted
    /// abbreviation, not an initial.
    private static func isSingleInitial(_ characters: [Character], endingAt dotIndex: Int) -> Bool {
        guard dotIndex >= 1, characters[dotIndex - 1].isLetter else { return false }
        if dotIndex >= 2, characters[dotIndex - 2].isLetter || characters[dotIndex - 2] == "." { return false }
        return true
    }

    /// The word starting at `start` (letters only), lowercased.
    private static func wordStartingAt(_ characters: [Character], from start: Int) -> String? {
        var end = start
        while end < characters.count, characters[end].isLetter { end += 1 }
        guard end > start else { return nil }
        return String(characters[start..<end]).lowercased()
    }

    /// The known abbreviation ending at the "." at `dotIndex`, if any
    /// (compared case-insensitively, dots stripped). Returns nil when
    /// the word is not a known abbreviation.
    private static func abbreviationEndingAt(_ characters: [Character], endingAt dotIndex: Int) -> String? {
        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "st", "vs", "etc", "eg", "ie",
            "am", "pm", "us", "usa", "uk", "jr", "sr", "prof", "no",
            "approx", "fig", "eq", "al", "phd", "md", "edd", "dphil"
        ]
        var start = dotIndex - 1
        while start >= 0, characters[start].isLetter || characters[start] == "." {
            start -= 1
        }
        let word = String(characters[(start + 1)..<dotIndex])
            .replacingOccurrences(of: ".", with: "")
            .lowercased()
        return abbreviations.contains(word) ? word : nil
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
