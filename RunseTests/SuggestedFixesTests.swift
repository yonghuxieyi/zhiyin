import RunseCore
import XCTest

/// Unit tests for the Claude-audit suggested fixes: segmentation
/// (blank lines, decimals/abbreviations/URLs), single-pass prompt
/// rendering, per-segment glossary filtering, no-fallback error
/// classes, dual-model review flagging, and the scanned-page
/// heuristic. Live-service behaviour is not covered here.
final class SuggestedFixesTests: XCTestCase {

    // MARK: - Segmentation: blank lines

    func testBlankLinesArePreservedAsEmptySegments() {
        let segments = TextSegmenter.segments(for: "第一段。\n\n第二段。", maxChars: 800)
        XCTAssertEqual(segments, ["第一段。", "", "第二段。"])
    }

    func testConsecutiveBlankLinesCollapseToOne() {
        let segments = TextSegmenter.segments(for: "第一段。\n\n\n\n第二段。", maxChars: 800)
        XCTAssertEqual(segments, ["第一段。", "", "第二段。"])
    }

    func testLeadingAndTrailingBlankLinesAreDropped() {
        let segments = TextSegmenter.segments(for: "\n\n第一段。\n\n", maxChars: 800)
        XCTAssertEqual(segments, ["第一段。"])
    }

    // MARK: - Segmentation: "." is not always a sentence end

    func testDecimalIsNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("圆周率约 3.14，很常用。"),
            ["圆周率约 3.14，很常用。"]
        )
    }

    func testURLAndDomainAreNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("Visit example.com for details. It helps."),
            ["Visit example.com for details.", " It helps."]
        )
    }

    func testAbbreviationsAreNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("Mr. Smith arrived at 9 a.m. He was early."),
            ["Mr. Smith arrived at 9 a.m.", " He was early."]
        )
    }

    func testNormalPeriodStillSplits() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("He came. He left."),
            ["He came.", " He left."]
        )
    }

    // MARK: - PromptRenderer: single pass

    func testValueContainingPlaceholderIsNotRescanned() {
        let template = PromptTemplate.builtIns().first { $0.action == .translate }!
        let prompt = PromptRenderer.render(
            template: template,
            context: PromptContext(
                selectedText: "the tone is {{tone}} here",
                action: .translate,
                targetLanguage: "English",
                tone: .natural,
                customInstruction: ""
            )
        )
        // The literal "{{tone}}" inside the selected text must survive
        // verbatim; the old multi-pass replace turned it into "natural".
        XCTAssertTrue(prompt.user.contains("{{tone}}"))
        XCTAssertFalse(prompt.user.contains("the tone is natural here"))
    }

    func testUnknownPlaceholderIsLeftAsIs() {
        let template = PromptTemplate(
            id: "test-template", action: .translate, name: "test",
            systemTemplate: "Do {{unknown_thing}} now.",
            userTemplate: "{{selected_text}}"
        )
        let prompt = PromptRenderer.render(template: template, context: PromptContext(selectedText: "hi", action: .translate))
        XCTAssertTrue(prompt.system.contains("{{unknown_thing}}"))
        XCTAssertEqual(prompt.user, "hi")
    }

    // MARK: - Glossary: only terms in this segment

    func testGlossaryFiltersToTermsInSegment() {
        let entries = [
            GlossaryEntry(sourceTerm: "API", targetTranslation: "接口"),
            GlossaryEntry(sourceTerm: "数据库", targetTranslation: "database"),
        ]
        let kept = GlossaryPrompt.entries(for: "调用这个 API 很快", from: entries)
        XCTAssertEqual(kept.map(\.sourceTerm), ["API"])
        XCTAssertEqual(GlossaryPrompt.entries(for: "今天天气很好", from: entries), [])
    }

    // MARK: - Pipeline: which errors may fall back

    func testCancellationNeverFallsBack() {
        XCTAssertFalse(TranslationPipeline.canFallback(for: CancellationError()))
    }

    func testAuthAndBillingErrorsNeverFallBack() {
        XCTAssertFalse(TranslationPipeline.canFallback(for: LLMProviderError.invalidStatus(401, "bad key", nil)))
        XCTAssertFalse(TranslationPipeline.canFallback(for: LLMProviderError.invalidStatus(402, "no balance", nil)))
    }

    func testRateLimitAndServerErrorsMayFallBack() {
        XCTAssertTrue(TranslationPipeline.canFallback(for: LLMProviderError.invalidStatus(429, "slow down", nil)))
        XCTAssertTrue(TranslationPipeline.canFallback(for: LLMProviderError.invalidStatus(500, "boom", nil)))
        XCTAssertTrue(TranslationPipeline.canFallback(for: LLMProviderError.timeout))
        XCTAssertTrue(TranslationPipeline.canFallback(for: LLMProviderError.emptyOutput))
    }

    // MARK: - LLMProviderError: Chinese messages

    func testProviderErrorsAreChinese() {
        XCTAssertTrue(LLMProviderError.invalidStatus(401, "", nil).errorDescription?.contains("API Key") ?? false)
        XCTAssertTrue(LLMProviderError.invalidStatus(402, "", nil).errorDescription?.contains("余额") ?? false)
        XCTAssertTrue(LLMProviderError.invalidStatus(429, "", nil).errorDescription?.contains("频繁") ?? false)
        XCTAssertTrue(LLMProviderError.missingAPIKey.errorDescription?.contains("API Key") ?? false)
    }

    // MARK: - DualModel: disagreement flags review

    func testDisagreementNeedsReview() {
        let verdict = DualModelCompare.compare(
            primary: "这个应用程序很快",
            second: "这个接口很快",
            source: "This API is fast",
            glossary: [GlossaryTerm(source: "API", target: "接口")]
        )
        XCTAssertFalse(verdict.agreed)
        XCTAssertTrue(verdict.needsReview)
        XCTAssertTrue(verdict.reason.contains("人工复核"))
    }

    func testAgreementDoesNotNeedReview() {
        let verdict = DualModelCompare.compare(primary: "你好，世界", second: "你好，世界", source: "Hello, world", glossary: [])
        XCTAssertTrue(verdict.agreed)
        XCTAssertFalse(verdict.needsReview)
    }

    // MARK: - Interpretation: latency and speaker-change

    func testLatencyIsSampledAtFirstTranslationText() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn, mode: .live)
        assembler.apply(.sourcePartial(text: "你好"))
        assembler.apply(.sourceFinal(text: "你好", startMs: 0, endMs: 1000, speakerChanged: false))
        assembler.apply(.translationPartial(text: "Hello"))
        assembler.apply(.translationFinal(text: "Hello", startMs: 1200, endMs: 2000, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 1)
        let latency = assembler.segments[0].latencyMs
        XCTAssertNotNil(latency, "latency must be sampled when the first translation text arrives, not at sourceFinal")
        XCTAssertGreaterThanOrEqual(latency ?? -1, 0)
    }

    func testSourceSpeakerChangeDoesNotLeakIntoTranslationSettle() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn, mode: .live)
        assembler.apply(.sourceStarted(speakerChanged: true))
        // Translation settles first: the source-side flag must not
        // mark this segment yet (old single-flag code did).
        assembler.apply(.translationFinal(text: "Hello", startMs: 0, endMs: 1000, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 1)
        XCTAssertFalse(assembler.segments[0].speakerChanged)
        // Source settles second and pairs in: now the flag applies.
        assembler.apply(.sourceFinal(text: "你好", startMs: 0, endMs: 1000, speakerChanged: false))
        XCTAssertTrue(assembler.segments[0].speakerChanged)
    }

    // MARK: - PDF: scanned-page heuristic

    func testSparseTextCountsAsScanned() {
        XCTAssertTrue(PDFTranslation.looksScanned(charCount: 5, textCoverage: 0.002))
        XCTAssertFalse(PDFTranslation.looksScanned(charCount: 5, textCoverage: 0.05))
        XCTAssertFalse(PDFTranslation.looksScanned(charCount: 500, textCoverage: 0.002))
    }
}
