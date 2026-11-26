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

    /// The result of a translation run that may have stopped early:
    /// the segments finished so far, plus where and why it stopped.
    /// Callers show the finished part and mark the failed segment
    /// instead of throwing the whole run away. Not Sendable (it
    /// carries the raw `Error`); it only ever crosses @MainActor
    /// boundaries, like the pipeline itself.
    public struct TranslationOutcome {
        public var results: [SegmentResult]
        /// Index into the input segments where translation stopped,
        /// nil when every segment finished.
        public var failedSegmentIndex: Int?
        public var error: Error?

        public var isComplete: Bool { failedSegmentIndex == nil }
    }

    /// Translates `segments` in order. `onSegmentUpdate` fires with the
    /// segment index and its current partial translation as chunks stream
    /// in. Returns the finished translations in segment order.
    /// `customInstruction` lands in the template's Instruction line
    /// (not in the text to translate); the interpretation fallback
    /// uses it to re-ask with missed glossary terms spelled out.
    /// `tone` appends a register instruction to the system prompt.
    /// When `fallbackProfile`/`fallbackAPIKey` are given, a segment
    /// that fails on the primary provider is retried once on the
    /// backup (Qwen-MT) instead of failing the whole call — except for
    /// errors where the backup cannot help: cancellation, and 401/402
    /// (a wrong key or an empty balance fails the same way on any
    /// provider, so retrying only burns a second call).
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
        let outcome = try await translatePartial(
            segments: segments, profile: profile, apiKey: apiKey,
            targetLanguage: targetLanguage, template: template,
            glossary: glossary, customInstruction: customInstruction,
            tone: tone, fallbackProfile: fallbackProfile,
            fallbackAPIKey: fallbackAPIKey, onSegmentUpdate: onSegmentUpdate
        )
        if let error = outcome.error { throw error }
        return outcome.results
    }

    /// Same as `translate`, but a failed segment stops the run and
    /// returns the finished part instead of throwing it away.
    /// Cancellation is the one exception: it is rethrown, never
    /// reported as a partial result.
    @MainActor public func translatePartial(
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
    ) async throws -> TranslationOutcome {
        lastUsage = [:]
        lastFallbackUsed = false
        var results: [SegmentResult] = []
        var previous: SegmentResult?
        for (index, segment) in segments.enumerated() {
            // Blank lines (paragraph spacing) pass through without a
            // provider call.
            if segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(SegmentResult(source: segment, translation: segment, providerID: profile.id))
                continue
            }
            var translation: String
            var usedProfile = profile
            do {
                translation = try await translateSegment(
                    segment, index: index, profile: profile, apiKey: apiKey,
                    targetLanguage: targetLanguage, template: template,
                    glossary: glossary, customInstruction: customInstruction,
                    tone: tone, previous: previous, onSegmentUpdate: onSegmentUpdate
                )
            } catch {
                if error is CancellationError { throw error }
                guard Self.canFallback(for: error),
                      let fallbackProfile, let fallbackAPIKey, !fallbackAPIKey.isEmpty else {
                    return TranslationOutcome(results: results, failedSegmentIndex: index, error: error)
                }
                lastFallbackUsed = true
                usedProfile = fallbackProfile
                do {
                    translation = try await translateSegment(
                        segment, index: index, profile: fallbackProfile, apiKey: fallbackAPIKey,
                        targetLanguage: targetLanguage, template: template,
                        glossary: glossary, customInstruction: customInstruction,
                        tone: tone, previous: previous, onSegmentUpdate: onSegmentUpdate
                    )
                } catch {
                    if error is CancellationError { throw error }
                    return TranslationOutcome(results: results, failedSegmentIndex: index, error: error)
                }
            }
            let done = SegmentResult(source: segment, translation: translation, providerID: usedProfile.id)
            results.append(done)
            previous = done
        }
        return TranslationOutcome(results: results, failedSegmentIndex: nil, error: nil)
    }

    /// Errors the backup provider cannot fix: cancellation (the user
    /// stopped the run), and 401/402 (a wrong key or an empty balance
    /// fails identically on the backup — retrying only burns a second
    /// call and hides the real problem). Everything else (429, 5xx,
    /// timeouts, network errors, empty output) may succeed on the
    /// backup and is worth one retry.
    public static func canFallback(for error: Error) -> Bool {
        if error is CancellationError { return false }
        if let providerError = error as? LLMProviderError,
           case .invalidStatus(let code, _, _) = providerError,
           code == 401 || code == 402 {
            return false
        }
        return true
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
        previous: SegmentResult?,
        onSegmentUpdate: @escaping (Int, String) -> Void
    ) async throws -> String {
        let client = HTTPProviderClient(profile: profile, apiKey: apiKey)
        // Only the glossary terms that appear in THIS segment: the
        // whole glossary wastes tokens and can leak unrelated terms
        // into the translation.
        let segmentGlossary = GlossaryPrompt.entries(for: segment, from: glossary)
        let glossaryBlock = GlossaryPrompt.block(for: segmentGlossary)
        // Segment-to-segment context: the previous source sentence and
        // its translation, so pronouns and term choices stay consistent
        // across the seam. Capped so a long document does not grow the
        // prompt without bound.
        var instruction = customInstruction
        if let previous {
            let prevSource = String(previous.source.prefix(200))
            let prevTranslation = String(previous.translation.prefix(200))
            let contextNote = "Previous sentence: \(prevSource)\nIts translation: \(prevTranslation)\nKeep pronouns, tense, and term choices consistent with it."
            instruction = instruction.isEmpty ? contextNote : instruction + "\n\n" + contextNote
        }
        let context = PromptContext(
            selectedText: segment,
            action: .translate,
            targetLanguage: targetLanguage,
            customInstruction: instruction
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
            glossaryTerms: segmentGlossary
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
