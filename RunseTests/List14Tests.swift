import RunseCore
import XCTest

/// Unit tests for the list 1–14 work (清单 1–14). Live-service behaviour
/// (Qwen-MT calls, streaming TTS, voice cloning) is NOT covered here:
/// those need real keys and a real device, and are verified by CI build
/// plus on-device testing when the phone is available.
final class List14Tests: XCTestCase {

    // MARK: - 清单 2: Qwen-MT request shape

    func testQwenMTBodyHasSingleUserMessageAndExtraBody() {
        let profile = ProviderProfile.qwenMTFlash()
        let request = LLMRequest(
            action: .translate,
            model: QwenMT.flashModel,
            systemPrompt: "You are a translator.",
            userPrompt: "你好，世界",
            targetLanguage: "English",
            glossaryTerms: [GlossaryTerm(source: "API", target: "接口")]
        )
        let body = ProviderRequestFactory.body(profile: profile, request: request)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        XCTAssertEqual(messages?.first?["content"] as? String, "你好，世界")
        XCTAssertNil(body["temperature"], "Qwen-MT does not take a temperature parameter")
        let extra = body["extra_body"] as? [String: Any]
        let options = extra?["translation_options"] as? [String: Any]
        XCTAssertEqual(options?["source_lang"] as? String, "auto")
        XCTAssertEqual(options?["target_lang"] as? String, "English")
        let terms = options?["terms"] as? [[String: String]]
        XCTAssertEqual(terms, [["source": "API", "target": "接口"]])
    }

    func testQwenMTBodyTargetLanguageChinese() {
        let profile = ProviderProfile.qwenMTPlus()
        let request = LLMRequest(
            action: .translate,
            model: QwenMT.plusModel,
            systemPrompt: "sys",
            userPrompt: "Hello, world",
            targetLanguage: "中文"
        )
        let body = ProviderRequestFactory.body(profile: profile, request: request)
        let options = (body["extra_body"] as? [String: Any])?["translation_options"] as? [String: Any]
        XCTAssertEqual(options?["target_lang"] as? String, "Chinese")
        XCTAssertNil(options?["terms"], "No glossary terms means no terms key")
    }

    func testQwenMTSegmentCapIsWellBelowOutputLimit() {
        XCTAssertEqual(TextSegmenter.maxChars(for: .qwenMTFlash()), QwenMT.maxSegmentChars)
        XCTAssertEqual(QwenMT.maxSegmentChars, 1500)
        XCTAssertEqual(TextSegmenter.maxChars(for: .defaultDeepSeek()), TextSegmenter.defaultMaxChars)
        XCTAssertEqual(TextSegmenter.defaultMaxChars, 800)
    }

    func testQwenMTProfilesAreOpenAICompatibleDashScope() {
        let flash = ProviderProfile.qwenMTFlash()
        XCTAssertTrue(flash.isQwenMT)
        XCTAssertEqual(flash.baseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(flash.model, "qwen-mt-flash")
        XCTAssertFalse(ProviderProfile.defaultDeepSeek().isQwenMT)
    }

    // MARK: - 清单 3: voice options

    func testSpeechRateParamMapping() {
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 0.5), -50)
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 1.0), 0)
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 1.5), 50)
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 2.0), 100)
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 0.3), -50, "Below range clamps to -50")
        XCTAssertEqual(VoiceSettings.speechRateParam(for: 3.0), 100, "Above range clamps to 100")
    }

    func testSpeakerCatalogOnlyUsesVerified2_0Voices() {
        XCTAssertEqual(DoubaoSpeaker.default.id, "zh_female_gaolengyujie_uranus_bigtts")
        XCTAssertEqual(DoubaoSpeaker.all.filter { $0.gender == .female }.count, 5)
        XCTAssertEqual(DoubaoSpeaker.all.filter { $0.gender == .male }.count, 4)
        for speaker in DoubaoSpeaker.all {
            XCTAssertTrue(speaker.id.hasSuffix("_uranus_bigtts"), "\(speaker.id) is not a verified 2.0 voice")
        }
    }

    // MARK: - 清单 4: tone modes

    func testToneTitlesAndInstructions() {
        XCTAssertEqual(TranslationTone.formal.title, "正式")
        XCTAssertEqual(TranslationTone.colloquial.title, "口语")
        XCTAssertEqual(TranslationTone.polite.title, "礼貌")
        XCTAssertEqual(TranslationTone.business.title, "商务")
        XCTAssertTrue(TranslationTone.formal.instruction.isEmpty == false)
        XCTAssertTrue(TranslationTone.colloquial.instruction.isEmpty == false)
        XCTAssertTrue(TranslationTone.polite.instruction.isEmpty == false)
        XCTAssertTrue(TranslationTone.business.instruction.isEmpty == false)
        XCTAssertTrue(TranslationTone.default.instruction.isEmpty, "Default tone adds nothing to the prompt")
    }

    // MARK: - 清单 6: history export

    func testHistoryExportContainsSourceResultAndTokens() {
        let item = TransformHistory(
            providerID: "deepseek-flash-1",
            sourceExcerpt: "你好",
            resultExcerpt: "Hello",
            providerName: "DeepSeek",
            model: "deepseek-flash",
            action: .translate,
            targetLanguage: "English",
            status: "success",
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15
        )
        let text = HistoryExporter.text(for: [item])
        XCTAssertTrue(text.contains("你好"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("deepseek-flash"))
        XCTAssertTrue(text.contains("15"))
    }

    func testHistoryExportOmitsTokenLineWhenNoUsageRecorded() {
        let item = TransformHistory(
            providerID: "deepseek-flash-1",
            sourceExcerpt: "你好",
            resultExcerpt: "Hello",
            providerName: "DeepSeek",
            model: "deepseek-flash",
            action: .translate,
            targetLanguage: "English",
            status: "success"
        )
        XCTAssertFalse(HistoryExporter.text(for: [item]).contains("Token"))
    }

    // MARK: - 清单 7: DeepSeek spend

    func testSpendCostFlashAndPro() {
        XCTAssertEqual(SpendCalculator.costYuan(promptTokens: 1_000_000, completionTokens: 1_000_000, model: "deepseek-flash"), 10)
        XCTAssertEqual(SpendCalculator.costYuan(promptTokens: 1_000_000, completionTokens: 1_000_000, model: "deepseek-v4-pro"), 36)
    }

    func testSpendSummaryCountsOnlyDeepSeek() {
        let flash = TransformHistory(
            providerID: "deepseek-flash-1",
            sourceExcerpt: "a", resultExcerpt: "b", providerName: "DeepSeek",
            model: "deepseek-flash", action: .translate, targetLanguage: "English",
            status: "success", promptTokens: 1_000_000, completionTokens: 1_000_000, totalTokens: 2_000_000
        )
        let qwen = TransformHistory(
            providerID: QwenMT.flashProfileID,
            sourceExcerpt: "a", resultExcerpt: "b", providerName: "Qwen-MT 备用",
            model: "qwen-mt-flash", action: .translate, targetLanguage: "English",
            status: "success", promptTokens: 1_000_000, completionTokens: 1_000_000, totalTokens: 2_000_000
        )
        let summary = SpendCalculator.summary(for: [flash, qwen])
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.totalTokens, 2_000_000)
        XCTAssertEqual(summary.costYuan, 10)
    }
}
