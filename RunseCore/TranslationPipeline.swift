import Foundation

/// Long-text translation pipeline shared by the text, voice and photo
/// screens. Translates segment by segment (streaming, so progress shows),
/// with the glossary injected into the system prompt so terms stay
/// consistent. Translation calls always use temperature 0.2 and DeepSeek
/// thinking disabled (handled by `ProviderRequestFactory`).
public final class TranslationPipeline {
    public struct SegmentResult: Sendable {
        public var source: String
        public var translation: String
        /// Profile id that produced this segment — the primary profile,
        /// or the fallback profile when the primary failed for it.
        public var providerID: String
    }

    /// Token usage of the last `translate` call, summed over all
    /// segments (primary and fallback). Views record it into history so
    /// the spend page can show real numbers.
    public private(set) var lastUsage: [String: Int] = [:]
    /// True when at least one segment fell back to the backup provider.
    public private(set) var lastFallbackUsed = false

    public init() {}

    /// Translates `segments` in order. `onSegmentUpdate` fires with the
    /// segment index and its current partial translation as chunks stream
    /// in. Returns the finished translations in segment order.
    /// `customInstruction` lands in the template's Instruction line
    /// (not in the text to translate); the interpretation fallback
    /// uses it to re-ask with missed glossary terms spelled out.
    /// `tone` appends a register instruction to the system prompt.
    /// When `fallbackProfile`/`fallbackAPIKey` are given, a segment
    /// that fails on the primary provider is retried once on the
    /// backup (Qwen-MT) instead of failing the whole call.
    @MainActor public func translate(
        segments: [String],
        profile: ProviderProfile,
        apiKey: String,
        targetLanguage: String,
        template: PromptTemplate,
        glossary: [GlossaryEntry],
        customInstruction: String = "",
        tone: TranslationTone = .default,
        fallbackProfile: ProviderProfile? = nil,
        fallbackAPIKey: String? = nil,
        onSegmentUpdate: @escaping (Int, String) -> Void
    ) async throws -> [SegmentResult] {
        lastUsage = [:]
        lastFallbackUsed = false
        var results: [SegmentResult] = []
        for (index, segment) in segments.enumerated() {
            var translation: String
            var usedProfile = profile
            do {
                translation = try await translateSegment(
                    segment, index: index, profile: profile, apiKey: apiKey,
                    targetLanguage: targetLanguage, template: template,
                    glossary: glossary, customInstruction: customInstruction,
                    tone: tone, onSegmentUpdate: onSegmentUpdate
                )
            } catch {
                guard let fallbackProfile, let fallbackAPIKey, !fallbackAPIKey.isEmpty else { throw error }
                lastFallbackUsed = true
                usedProfile = fallbackProfile
                translation = try await translateSegment(
                    segment, index: index, profile: fallbackProfile, apiKey: fallbackAPIKey,
                    targetLanguage: targetLanguage, template: template,
                    glossary: glossary, customInstruction: customInstruction,
                    tone: tone, onSegmentUpdate: onSegmentUpdate
                )
            }
            results.append(SegmentResult(source: segment, translation: translation, providerID: usedProfile.id))
        }
        return results
    }

    @MainActor private func translateSegment(
        _ segment: String,
        index: Int,
        profile: ProviderProfile,
        apiKey: String,
        targetLanguage: String,
        template: PromptTemplate,
        glossary: [GlossaryEntry],
        customInstruction: String,
        tone: TranslationTone,
        onSegmentUpdate: @escaping (Int, String) -> Void
    ) async throws -> String {
        let client = HTTPProviderClient(profile: profile, apiKey: apiKey)
        let glossaryBlock = GlossaryPrompt.block(for: glossary)
        let context = PromptContext(
            selectedText: segment,
            action: .translate,
            targetLanguage: targetLanguage,
            customInstruction: customInstruction
        )
        var prompt = PromptRenderer.render(template: template, context: context)
        var system = prompt.system
        if !tone.instruction.isEmpty {
            system += "\n\n" + tone.instruction
        }
        if !glossaryBlock.isEmpty {
            system += "\n\n" + glossaryBlock
        }
        prompt = RenderedPrompt(system: system, user: prompt.user)
        let request = LLMRequest(
            action: .translate,
            model: profile.model,
            systemPrompt: prompt.system,
            userPrompt: prompt.user,
            temperature: 0.2,
            targetLanguage: targetLanguage,
            glossaryTerms: glossary
                .filter { !$0.targetTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { GlossaryTerm(source: $0.sourceTerm, target: $0.targetTranslation) }
        )
        var translation = ""
        let response = try await client.complete(request) { partial in
            translation = partial
            onSegmentUpdate(index, partial)
        }
        translation = response.text
        onSegmentUpdate(index, translation)
        for (key, value) in response.usage {
            lastUsage[key, default: 0] += value
        }
        return translation
    }
}
