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
    }

    public init() {}

    /// Translates `segments` in order. `onSegmentUpdate` fires with the
    /// segment index and its current partial translation as chunks stream
    /// in. Returns the finished translations in segment order.
    @MainActor public func translate(
        segments: [String],
        profile: ProviderProfile,
        apiKey: String,
        targetLanguage: String,
        template: PromptTemplate,
        glossary: [GlossaryEntry],
        onSegmentUpdate: @escaping (Int, String) -> Void
    ) async throws -> [SegmentResult] {
        let client = HTTPProviderClient(profile: profile, apiKey: apiKey)
        let glossaryBlock = GlossaryPrompt.block(for: glossary)
        var results: [SegmentResult] = []
        for (index, segment) in segments.enumerated() {
            let context = PromptContext(
                selectedText: segment,
                action: .translate,
                targetLanguage: targetLanguage,
                customInstruction: ""
            )
            var prompt = PromptRenderer.render(template: template, context: context)
            if !glossaryBlock.isEmpty {
                prompt = RenderedPrompt(system: prompt.system + "\n\n" + glossaryBlock, user: prompt.user)
            }
            let request = LLMRequest(
                action: .translate,
                model: profile.model,
                systemPrompt: prompt.system,
                userPrompt: prompt.user,
                temperature: 0.2
            )
            var translation = ""
            let response = try await client.complete(request) { partial in
                translation = partial
                onSegmentUpdate(index, partial)
            }
            translation = response.text
            onSegmentUpdate(index, translation)
            results.append(SegmentResult(source: segment, translation: translation))
        }
        return results
    }
}
