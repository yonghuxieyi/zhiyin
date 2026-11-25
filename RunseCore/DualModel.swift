import Foundation

/// Dual-model cross-check (清单 14): for professional PDF translation,
/// a second model translates the same source and the two results are
/// compared. The boss's rule: off by default, on only when a
/// professional document needs it. The referee logic is deterministic
/// and unit-tested — it never silently picks the "nicer" one.
public enum DualModelCompare {
    public struct Verdict: Sendable, Equatable {
        /// True when the two translations are close enough to count as
        /// agreement (bigram Jaccard >= threshold).
        public var agreed: Bool
        /// The translation that is kept.
        public var chosen: String
        /// The other translation.
        public var other: String
        /// Human-readable reason, shown under the translated page.
        public var reason: String
        /// Whether the primary model's translation was kept.
        public var primaryWon: Bool

        public init(agreed: Bool, chosen: String, other: String, reason: String, primaryWon: Bool) {
            self.agreed = agreed
            self.chosen = chosen
            self.other = other
            self.reason = reason
            self.primaryWon = primaryWon
        }
    }

    /// Bigram Jaccard similarity at or above this counts as agreement.
    public static let agreementThreshold = 0.7

    /// Compares two translations of the same source. Pure function.
    /// Referee, in order: (1) a translation that respects more
    /// glossary terms wins; (2) a translation with a sane length wins
    /// over an empty or wildly off-length one; (3) otherwise the
    /// primary model's translation is kept.
    public static func compare(
        primary: String,
        second: String,
        source: String,
        glossary: [GlossaryTerm],
        primaryName: String = "DeepSeek",
        secondName: String = "Qwen-MT"
    ) -> Verdict {
        let primaryTrimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondTrimmed = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if primaryTrimmed.isEmpty, secondTrimmed.isEmpty {
            return Verdict(agreed: true, chosen: primary, other: second, reason: "两模型都没翻出内容。", primaryWon: true)
        }
        if primaryTrimmed.isEmpty {
            return Verdict(agreed: false, chosen: second, other: primary, reason: "主模型没翻出内容，改用\(secondName)。", primaryWon: false)
        }
        if secondTrimmed.isEmpty {
            return Verdict(agreed: false, chosen: primary, other: second, reason: "\(secondName)没翻出内容，保留\(primaryName)。", primaryWon: true)
        }
        let similarity = bigramSimilarity(primaryTrimmed, secondTrimmed)
        if similarity >= agreementThreshold {
            return Verdict(agreed: true, chosen: primary, other: second, reason: "两模型一致（相似度 \(Int(similarity * 100))%）。", primaryWon: true)
        }
        let primaryHits = glossaryHits(in: primaryTrimmed, glossary: glossary)
        let secondHits = glossaryHits(in: secondTrimmed, glossary: glossary)
        if primaryHits != secondHits {
            if primaryHits > secondHits {
                return Verdict(agreed: false, chosen: primary, other: second, reason: "有分歧：\(primaryName)术语命中 \(primaryHits) 个、\(secondName) \(secondHits) 个，选\(primaryName)。", primaryWon: true)
            }
            return Verdict(agreed: false, chosen: second, other: primary, reason: "有分歧：\(secondName)术语命中 \(secondHits) 个、\(primaryName) \(primaryHits) 个，选\(secondName)。", primaryWon: false)
        }
        let primaryLengthOK = saneLength(translation: primaryTrimmed, source: source)
        let secondLengthOK = saneLength(translation: secondTrimmed, source: source)
        if primaryLengthOK != secondLengthOK {
            if primaryLengthOK {
                return Verdict(agreed: false, chosen: primary, other: second, reason: "有分歧：\(secondName)译文长度异常，选\(primaryName)。", primaryWon: true)
            }
            return Verdict(agreed: false, chosen: second, other: primary, reason: "有分歧：\(primaryName)译文长度异常，选\(secondName)。", primaryWon: false)
        }
        return Verdict(agreed: false, chosen: primary, other: second, reason: "有分歧：两者术语命中相同（\(primaryHits) 个），保留主模型\(primaryName)。", primaryWon: true)
    }

    /// Character-bigram Jaccard similarity after normalizing
    /// whitespace and case. Pure function, covered by unit tests.
    public static func bigramSimilarity(_ a: String, _ b: String) -> Double {
        let aBigrams = bigrams(of: normalize(a))
        let bBigrams = bigrams(of: normalize(b))
        guard !aBigrams.isEmpty || !bBigrams.isEmpty else { return 1 }
        let intersection = aBigrams.intersection(bBigrams).count
        let union = aBigrams.union(bBigrams).count
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func bigrams(of text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return Set(chars.map(String.init)) }
        var result: Set<String> = []
        for i in 0..<(chars.count - 1) {
            result.insert(String([chars[i], chars[i + 1]]))
        }
        return result
    }

    private static func glossaryHits(in translation: String, glossary: [GlossaryTerm]) -> Int {
        glossary.filter { !$0.target.isEmpty && translation.contains($0.target) }.count
    }

    /// A translation is sane when it is between 30% and 300% of the
    /// source length (character count). Catches empty, truncated, or
    /// runaway outputs without judging style.
    private static func saneLength(translation: String, source: String) -> Bool {
        guard !source.isEmpty else { return !translation.isEmpty }
        let ratio = Double(translation.count) / Double(source.count)
        return ratio >= 0.3 && ratio <= 3.0
    }
}

/// Runs the second-model translation for the cross-check. The second
/// model is the complement of the primary: Qwen-MT Plus when the
/// primary is DeepSeek, DeepSeek Flash when the primary is Qwen-MT.
public enum DualModelChecker {
    public static func secondProfile(for primary: ProviderProfile, profiles: [ProviderProfile]) -> ProviderProfile? {
        if primary.isQwenMT {
            return profiles.first { $0.id == RunseConstants.defaultProfileID }
        }
        return profiles.first { $0.id == QwenMT.plusProfileID }
            ?? profiles.first { $0.isQwenMT }
    }

    /// Main-actor isolated: callers pass a profile that came from
    /// `@Query` state, which must not cross to nonisolated code.
    @MainActor
    public static func secondAPIKey(for profile: ProviderProfile) async -> String? {
        if profile.isQwenMT {
            return await DashScopeStore.loadKey()
        }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        return try? await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
    }

    /// Translates `source` with the second model and compares it with
    /// `primaryTranslation`. Returns the kept translation and the
    /// verdict. Throws when the second model cannot be called (no
    /// profile, no key, or a failed request) — the caller keeps the
    /// primary translation and reports the failure.
    ///
    /// `tone` must match the tone used for the primary translation,
    /// otherwise the two models are compared in different registers.
    ///
    /// Main-actor isolated on purpose: the caller passes its `@Query`
    /// profiles, and the translation pipeline it drives is main-actor
    /// isolated too.
    @MainActor
    public static func check(
        source: String,
        primaryTranslation: String,
        primary: ProviderProfile,
        targetLanguage: String,
        template: PromptTemplate,
        glossary: [GlossaryEntry],
        profiles: [ProviderProfile],
        tone: TranslationTone = .default
    ) async throws -> DualModelCompare.Verdict {
        guard let second = secondProfile(for: primary, profiles: profiles) else {
            throw LLMProviderError.invalidURL
        }
        guard let apiKey = await secondAPIKey(for: second), !apiKey.isEmpty else {
            throw LLMProviderError.missingAPIKey
        }
        let segments = TextSegmenter.segments(for: source, maxChars: TextSegmenter.maxChars(for: second))
        let results = try await TranslationPipeline().translate(
            segments: segments,
            profile: second,
            apiKey: apiKey,
            targetLanguage: targetLanguage,
            template: template,
            glossary: glossary,
            tone: tone
        ) { _, _ in }
        let secondTranslation = results.map(\.translation).joined(separator: "\n")
        let terms = glossary
            .filter { !$0.targetTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { GlossaryTerm(source: $0.sourceTerm, target: $0.targetTranslation) }
        return DualModelCompare.compare(
            primary: primaryTranslation,
            second: secondTranslation,
            source: source,
            glossary: terms,
            primaryName: primary.name,
            secondName: second.name
        )
    }
}
