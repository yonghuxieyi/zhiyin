import RunseCore
import XCTest

/// Segment assembly, output gate, quota, latency budget, and glossary
/// rules for simultaneous interpretation. All pure logic; the live
/// path itself is device-only.
final class InterpretationTests: XCTestCase {
    // MARK: - Segment assembler

    func testPartialReplacesDraftAndFinalSettles() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn)
        assembler.apply(.sourcePartial(text: "你好"))
        XCTAssertEqual(assembler.liveDraft.source, "你好")
        XCTAssertTrue(assembler.segments.isEmpty)
        // Self-correction mid-sentence: the draft is replaced.
        assembler.apply(.sourcePartial(text: "你好，世界"))
        XCTAssertEqual(assembler.liveDraft.source, "你好，世界")
        assembler.apply(.sourceFinal(text: "你好，世界", startMs: 40, endMs: 1200, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 1)
        XCTAssertEqual(assembler.segments[0].sourceText, "你好，世界")
        XCTAssertEqual(assembler.liveDraft.source, "")
        XCTAssertFalse(assembler.segments[0].isComplete)
    }

    func testTranslationPairsWithSourceByOrder() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn)
        assembler.apply(.sourceFinal(text: "你好，世界", startMs: 40, endMs: 1200, speakerChanged: false))
        assembler.apply(.translationPartial(text: "Hello"))
        assembler.apply(.translationFinal(text: "Hello, world", startMs: 2500, endMs: 3700, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 1)
        XCTAssertEqual(assembler.segments[0].translationText, "Hello, world")
        XCTAssertTrue(assembler.segments[0].isComplete)
        // Second sentence pairs with the second segment, not the first.
        assembler.apply(.sourceFinal(text: "今天天气很好", startMs: 4600, endMs: 5800, speakerChanged: false))
        assembler.apply(.translationFinal(text: "The weather is nice today", startMs: 6000, endMs: 7200, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 2)
        XCTAssertEqual(assembler.segments[1].sourceText, "今天天气很好")
        XCTAssertEqual(assembler.segments[1].translationText, "The weather is nice today")
    }

    func testSpeakerChangeMarksNextSegment() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn)
        assembler.apply(.sourceFinal(text: "你好", startMs: 40, endMs: 500, speakerChanged: false))
        assembler.apply(.sourceStarted(speakerChanged: true))
        assembler.apply(.sourceFinal(text: "你好", startMs: 900, endMs: 1400, speakerChanged: false))
        XCTAssertEqual(assembler.segments.count, 2)
        XCTAssertFalse(assembler.segments[0].speakerChanged)
        XCTAssertTrue(assembler.segments[1].speakerChanged)
    }

    func testFallbackAppend() {
        var assembler = InterpretationSegmentAssembler(direction: .zhToEn, mode: .fallback)
        assembler.appendFallback(source: "今天天气很好", translation: "The weather is nice today", latencyMs: 1200)
        XCTAssertEqual(assembler.segments.count, 1)
        XCTAssertEqual(assembler.segments[0].mode, .fallback)
        XCTAssertTrue(assembler.segments[0].isComplete)
    }

    // MARK: - Output gate

    func testGateKeepsMatchingLanguageOnly() {
        let chinese = InterpretationSegment(direction: .zhToEn, mode: .live, sourceText: "你好，世界", translationText: "Hello, world")
        let english = InterpretationSegment(direction: .enToZh, mode: .live, sourceText: "Hello, world", translationText: "你好，世界")
        XCTAssertTrue(InterpretationEngine.passesGate(chinese, expectedSource: .chinese))
        XCTAssertFalse(InterpretationEngine.passesGate(chinese, expectedSource: .english))
        XCTAssertTrue(InterpretationEngine.passesGate(english, expectedSource: .english))
        XCTAssertFalse(InterpretationEngine.passesGate(english, expectedSource: .chinese))
        // No source text yet: keep (the draft is still forming).
        let empty = InterpretationSegment(direction: .zhToEn, mode: .live, sourceText: "", translationText: "Hello")
        XCTAssertTrue(InterpretationEngine.passesGate(empty, expectedSource: .english))
    }

    // MARK: - Quota

    func testQuotaAccumulatesAndWarns() {
        let defaults = UserDefaults(suiteName: "zhiyin-test-quota")!
        defaults.removePersistentDomain(forName: "zhiyin-test-quota")
        let store = InterpretationQuotaStore(defaults: defaults)
        var snapshot = store.snapshot()
        XCTAssertEqual(snapshot.liveSessionsToday, 0)
        XCTAssertFalse(snapshot.liveSessionsWarning)
        for _ in 0..<16 {
            store.recordLiveSession(durationMsec: 60000, inputAudioTokens: 375, outputTextTokens: 20, outputAudioTokens: 15)
        }
        snapshot = store.snapshot()
        XCTAssertEqual(snapshot.liveSessionsToday, 16)
        XCTAssertEqual(snapshot.liveSessionsRemaining, 4)
        XCTAssertTrue(snapshot.liveSessionsWarning)
        XCTAssertEqual(snapshot.liveMinutesToday, 16, accuracy: 0.001)
        store.recordASR(minutes: 17 * 60)
        store.recordTTS(chars: 17000)
        snapshot = store.snapshot()
        XCTAssertTrue(snapshot.asrWarning)
        XCTAssertTrue(snapshot.ttsWarning)
        XCTAssertEqual(snapshot.asrMinutesRemaining, 3 * 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.ttsCharsRemaining, 3000)
        defaults.removePersistentDomain(forName: "zhiyin-test-quota")
    }

    func testQuotaBalance() {
        let defaults = UserDefaults(suiteName: "zhiyin-test-quota-balance")!
        defaults.removePersistentDomain(forName: "zhiyin-test-quota-balance")
        let store = InterpretationQuotaStore(defaults: defaults)
        XCTAssertNil(store.snapshot().balanceYuan)
        store.setBalance(2.36, asOf: Date(timeIntervalSince1970: 0))
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.balanceYuan, 2.36)
        XCTAssertEqual(snapshot.balanceAsOf, Date(timeIntervalSince1970: 0))
        defaults.removePersistentDomain(forName: "zhiyin-test-quota-balance")
    }

    // MARK: - Latency budget

    func testLatencyBudgetWithDocumentedNumbers() {
        let budget = LatencyBudget()
        // Documented service latency 2.53s + playback buffer
        // (100ms since list item 13 trimmed it from 150ms).
        XCTAssertEqual(budget.pipelinedMs, 2630, accuracy: 0.001)
        XCTAssertEqual(budget.worstCaseMs, 2860, accuracy: 0.001)
        // Honest result: within the 3s hard limit, above the 2.5s
        // target on documented numbers alone — the target needs the
        // service to run faster than its documented figure, or a
        // measured first-audio sample to prove otherwise.
        XCTAssertTrue(budget.withinLimit)
        XCTAssertFalse(budget.meetsTarget)
    }

    func testLatencyMeasurementVerdicts() {
        let fast = LatencyBudget.Measurement(firstTranslationTextMs: 1800, firstTTSAudioMs: 2200, sessionStartToFirstTranslationMs: 2500)
        XCTAssertEqual(fast.endToEndMs, 2200)
        XCTAssertTrue(fast.meetsTarget)
        XCTAssertTrue(fast.withinLimit)
        let slow = LatencyBudget.Measurement(firstTranslationTextMs: 2600, firstTTSAudioMs: 3100, sessionStartToFirstTranslationMs: 3400)
        XCTAssertFalse(slow.meetsTarget)
        XCTAssertFalse(slow.withinLimit)
        let none = LatencyBudget.Measurement()
        XCTAssertNil(none.endToEndMs)
        XCTAssertFalse(none.meetsTarget)
    }

    // MARK: - Glossary

    func testGlossaryListFiltersSortsAndCaps() {
        let entries = [
            GlossaryEntry(sourceTerm: "智音", targetTranslation: "Zhiyin"),
            GlossaryEntry(sourceTerm: "人工智能", targetTranslation: ""),
            GlossaryEntry(sourceTerm: "量子计算", targetTranslation: "quantum computing"),
        ]
        let list = GlossaryAST.glossaryList(from: entries)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].source, "智音")
        XCTAssertEqual(list[1].source, "量子计算")
    }

    func testMissingTermsPostCheck() {
        let glossary = [("智音", "Zhiyin"), ("量子计算", "quantum computing")]
        XCTAssertTrue(GlossaryAST.missingTerms(in: "Welcome to Zhiyin", glossary: glossary).map(\.source) == ["量子计算"])
        XCTAssertTrue(GlossaryAST.missingTerms(in: "Welcome to Zhiyin, quantum computing", glossary: glossary).isEmpty)
    }
}
