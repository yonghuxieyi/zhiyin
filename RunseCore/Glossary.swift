import Foundation
import SwiftData

/// A term the user wants translated the same way every time. The source
/// term is extracted automatically from long text; the target translation
/// starts empty and the user fills it in. Only entries with a non-empty
/// target are injected into translation prompts.
@Model public final class GlossaryEntry {
    @Attribute(.unique) public var id: String
    public var sourceTerm: String
    public var targetTranslation: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, sourceTerm: String, targetTranslation: String = "", createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.sourceTerm = sourceTerm
        self.targetTranslation = targetTranslation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Finds candidate glossary terms in a passage: words that repeat.
/// Chinese: 2–4 character windows appearing at least twice. English:
/// words of 3+ letters appearing at least twice. Common function words
/// are filtered out. Pure functions, covered by unit tests.
public enum GlossaryExtractor {
    private static let chineseStopwords: Set<String> = [
        "的", "了", "是", "在", "和", "与", "或", "但", "如果", "因为", "所以",
        "这个", "那个", "这些", "那些", "我们", "你们", "他们", "她们", "它们",
        "自己", "可以", "应该", "能够", "进行", "一个", "一种", "一下", "一些",
        "没有", "不是", "就是", "还是", "只有", "以及", "同时", "然后", "这样",
        "那样", "怎么", "什么", "为什么", "时候", "地方", "问题", "方面", "情况",
        "中国", "这里", "那里", "其中", "通过", "对于",
        "由于", "随着", "作为", "关于", "根据", "包括", "例如", "比如", "但是"
    ]

    private static let englishStopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "were", "been", "will", "would", "could", "should", "there", "their",
        "which", "when", "what", "about", "into", "than", "then", "them",
        "also", "more", "most", "some", "such", "only", "over", "under",
        "after", "before", "between", "other", "these", "those", "being",
        "because", "while", "where", "your", "yours", "ours", "are"
    ]

    /// Returns candidate terms ordered by frequency, then length.
    public static func candidates(from text: String, maxCount: Int = 20) -> [(term: String, count: Int)] {
        var counts: [String: Int] = [:]
        extractChineseTerms(from: text, into: &counts)
        extractEnglishTerms(from: text, into: &counts)
        var ranked = counts
            .filter { $0.value >= 2 }
            .map { (term: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.term.count > rhs.term.count
            }
        // Drop a shorter term when a longer kept term with the same count
        // already contains it (e.g. keep 人工智能, drop 人工智).
        var kept: [(term: String, count: Int)] = []
        for candidate in ranked {
            let shadowed = kept.contains { keptTerm in
                keptTerm.count == candidate.count && keptTerm.term.contains(candidate.term)
            }
            if !shadowed { kept.append(candidate) }
            if kept.count >= maxCount { break }
        }
        ranked = kept
        return ranked
    }

    private static func extractChineseTerms(from text: String, into counts: inout [String: Int]) {
        let scalars = Array(text.unicodeScalars)
        for length in 2...4 {
            guard scalars.count >= length else { continue }
            for start in 0...(scalars.count - length) {
                let window = scalars[start..<(start + length)]
                guard window.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) else { continue }
                let term = String(window.map { Character($0) })
                guard !chineseStopwords.contains(term) else { continue }
                counts[term, default: 0] += 1
            }
        }
    }

    private static func extractEnglishTerms(from text: String, into counts: inout [String: Int]) {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { $0.count >= 3 && !englishStopwords.contains($0) }
        for word in words {
            counts[word, default: 0] += 1
        }
    }
}

/// Renders the glossary block appended to a translation system prompt so
/// the model keeps the same wording for the same term throughout.
public enum GlossaryPrompt {
    public static func block(for entries: [GlossaryEntry]) -> String {
        let fixed = entries.filter { !$0.targetTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !fixed.isEmpty else { return "" }
        let lines = fixed.map { "\($0.sourceTerm) -> \($0.targetTranslation)" }
        return "Terminology (translate these terms exactly this way every time they appear):\n" + lines.joined(separator: "\n")
    }

    /// Only the terms that actually appear in `text` — injecting the
    /// whole glossary into every segment wastes tokens and lets
    /// unrelated terms leak into the translation. Matching is a plain
    /// substring test (case-insensitive for Latin text, so "api"
    /// matches "API"); Chinese terms match as-is.
    public static func entries(for text: String, from entries: [GlossaryEntry]) -> [GlossaryEntry] {
        let lowerText = text.lowercased()
        return entries.filter { entry in
            guard !entry.targetTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.sourceTerm.isEmpty else { return false }
            if entry.sourceTerm.contains(where: { $0.isLetter && !$0.isASCII }) {
                return text.contains(entry.sourceTerm)
            }
            return lowerText.contains(entry.sourceTerm.lowercased())
        }
    }
}
