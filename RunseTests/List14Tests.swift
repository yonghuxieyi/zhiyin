import RunseCore
import XCTest

/// Unit tests for the list 1–14 work (清单 1–14). Live-service behaviour
/// (Qwen-MT calls, streaming TTS, voice cloning) is NOT covered here:
/// those need real keys and a real device, and are verified by CI build
/// plus on-device testing when the phone is available.
final class List14Tests: XCTestCase {

    // MARK: - 清单 2: Qwen-MT request shape

    func testQwenMTBodyHasSingleUserMessageAndTopLevelOptions() {
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
        // M2: translation_options is a top-level body field (official
        // curl example); extra_body was a Python-SDK-only mechanism.
        XCTAssertNil(body["extra_body"], "translation_options must not be nested under extra_body")
        let options = body["translation_options"] as? [String: Any]
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
        let options = body["translation_options"] as? [String: Any]
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

    // MARK: - 清单 12: 流式 TTS 帧编解码

    func testStreamingFrameStartConnectionEncodesExactly() {
        let payload = Data("{}".utf8)
        let frame = VolcanoTTSFrame.encode(type: VolcanoTTSFrame.fullClientRequest, event: 1, sessionID: nil, payload: payload, isJSON: true)
        // [0x11, type<<4|flag 0x4, 0x10 (JSON), 0x00, event 1, payload size 2, "{}"]
        let expected: [UInt8] = [0x11, 0x14, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x7B, 0x7D]
        XCTAssertEqual([UInt8](frame), expected)
        let decoded = VolcanoTTSFrame.decodeFirst(from: frame)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frame.event, 1)
        XCTAssertNil(decoded?.frame.sessionID, "Connection events carry no session id")
        XCTAssertEqual(decoded?.frame.payload, payload)
        XCTAssertEqual(decoded?.consumed, frame.count)
    }

    func testStreamingFrameAudioFrameFlag6Decodes() {
        // A server audio frame: type 0xB, flags 0x6 (LastNoSeq | WithEvent —
        // the flag value the official Python demo mishandles by comparing
        // flag == WithEvent instead of masking bits), event 352, a
        // session id, then raw PCM.
        var raw = Data([0x11, 0xB6, 0x00, 0x00])
        var event: Int32 = Int32(352).bigEndian
        raw.append(Data(bytes: &event, count: 4))
        let sessionID = Data("sess-1".utf8)
        var idLength = UInt32(sessionID.count).bigEndian
        raw.append(Data(bytes: &idLength, count: 4))
        raw.append(sessionID)
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        var payloadSize = UInt32(pcm.count).bigEndian
        raw.append(Data(bytes: &payloadSize, count: 4))
        raw.append(pcm)
        let decoded = VolcanoTTSFrame.decodeFirst(from: raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frame.type, 0xB)
        XCTAssertEqual(decoded?.frame.flags, 0x6)
        XCTAssertFalse(decoded?.frame.isJSON ?? true)
        XCTAssertEqual(decoded?.frame.event, 352)
        XCTAssertNil(decoded?.frame.sequence, "Flag 0x2 (LastNoSeq) carries no sequence")
        XCTAssertEqual(decoded?.frame.sessionID, "sess-1")
        XCTAssertEqual(decoded?.frame.payload, pcm)
        XCTAssertEqual(decoded?.consumed, raw.count)
    }

    func testStreamingFrameConnectionStartedCarriesConnectID() {
        // Event 50: no session id, but a connect id after the (empty)
        // session-id slot, then a JSON payload.
        var raw = Data([0x11, 0x94, 0x10, 0x00])
        var event: Int32 = Int32(50).bigEndian
        raw.append(Data(bytes: &event, count: 4))
        let connectID = Data("conn-1".utf8)
        var idLength = UInt32(connectID.count).bigEndian
        raw.append(Data(bytes: &idLength, count: 4))
        raw.append(connectID)
        let payload = Data("{}".utf8)
        var payloadSize = UInt32(payload.count).bigEndian
        raw.append(Data(bytes: &payloadSize, count: 4))
        raw.append(payload)
        let decoded = VolcanoTTSFrame.decodeFirst(from: raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.frame.event, 50)
        XCTAssertNil(decoded?.frame.sessionID)
        XCTAssertEqual(decoded?.frame.connectID, "conn-1")
        XCTAssertTrue(decoded?.frame.isJSON ?? false)
    }

    func testStreamingFrameTruncatedBufferReturnsNil() {
        let frame = VolcanoTTSFrame.encode(type: VolcanoTTSFrame.fullClientRequest, event: 100, sessionID: "s", payload: Data("{}".utf8), isJSON: true)
        XCTAssertNil(VolcanoTTSFrame.decodeFirst(from: frame.prefix(frame.count - 2)))
        XCTAssertNil(VolcanoTTSFrame.decodeFirst(from: Data([0x11, 0x14])))
    }

    // MARK: - 清单 8: 我的声音（服务端报错文案）

    func testQwenVoiceServerMessagePrefersMessageThenCode() {
        XCTAssertEqual(QwenVoiceClone.serverMessage(from: ["code": "InvalidApiKey", "message": "Key 无效"]), "Key 无效")
        XCTAssertEqual(QwenVoiceClone.serverMessage(from: ["code": "InvalidApiKey"]), "InvalidApiKey")
        XCTAssertEqual(QwenVoiceClone.serverMessage(from: [:]), "未知错误")
    }

    func testQwenAudioURLsUseWorkspaceDomainWhenGiven() {
        let withWorkspace = QwenAudio.customizationURL(workspaceID: "ws-123")
        XCTAssertEqual(withWorkspace?.absoluteString, "https://ws-123.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/customization")
        let legacy = QwenAudio.customizationURL(workspaceID: nil)
        XCTAssertEqual(legacy?.absoluteString, "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization")
    }

    // MARK: - 清单 14: 双模型交叉校对

    func testDualModelIdenticalTranslationsAgree() {
        let verdict = DualModelCompare.compare(primary: "你好，世界", second: "你好，世界", source: "Hello, world", glossary: [])
        XCTAssertTrue(verdict.agreed)
        XCTAssertTrue(verdict.primaryWon)
        XCTAssertEqual(verdict.chosen, "你好，世界")
    }

    func testDualModelGlossaryHitsDecideDisagreement() {
        let terms = [GlossaryTerm(source: "API", target: "接口")]
        let verdict = DualModelCompare.compare(
            primary: "这个应用程序很快",
            second: "这个接口很快",
            source: "This API is fast",
            glossary: terms
        )
        XCTAssertFalse(verdict.agreed)
        XCTAssertFalse(verdict.primaryWon, "The second model used the glossary term, so it wins")
        XCTAssertEqual(verdict.chosen, "这个接口很快")
    }

    func testDualModelAbnormalLengthLoses() {
        let verdict = DualModelCompare.compare(
            primary: "这是一个需要翻译的句子内容",
            second: "翻译",
            source: "This is a sentence to translate",
            glossary: []
        )
        XCTAssertFalse(verdict.agreed)
        XCTAssertTrue(verdict.primaryWon, "Primary is sane length, second is far too short relative to source")
    }

    func testDualModelEmptyBothAgreeOnPrimary() {
        let verdict = DualModelCompare.compare(primary: "", second: "", source: "Hello", glossary: [])
        XCTAssertTrue(verdict.agreed)
        XCTAssertEqual(verdict.chosen, "")
    }
}
