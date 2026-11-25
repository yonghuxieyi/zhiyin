import RunseCore
import XCTest

/// ASR result parsing rules, pinned to the real messages captured
/// live from bigmodel_async on 2026-11-25.
final class ASRResultTests: XCTestCase {
    func testSessionAckReturnsNil() {
        // First message: result with only additions.log_id, no text.
        let result: [String: Any] = ["additions": ["log_id": "20261125210911D11FABB34DF513371FAD"]]
        XCTAssertNil(VolcanoASRClient.parseASRResult(result))
    }

    func testPartialIsNotFinal() {
        let result: [String: Any] = [
            "text": "欢迎使用",
            "utterances": [["text": "欢迎使用", "definite": false, "start_time": 40, "end_time": 1000]]
        ]
        let parsed = VolcanoASRClient.parseASRResult(result)
        XCTAssertEqual(parsed?.text, "欢迎使用")
        XCTAssertEqual(parsed?.isFinal, false)
    }

    func testPrefetchIsNeverFinalEvenWhenDefinite() {
        // Re-recognition pass over a closed utterance: same text,
        // definite true, but prefetch means "not a new final".
        let result: [String: Any] = [
            "text": "欢迎使用智音翻译，人工智能正在改变我们的生活",
            "prefetch": true,
            "utterances": [["text": "欢迎使用智音翻译，人工智能正在改变我们的生活", "definite": true, "start_time": 40, "end_time": 3700]]
        ]
        let parsed = VolcanoASRClient.parseASRResult(result)
        XCTAssertEqual(parsed?.text, "欢迎使用智音翻译，人工智能正在改变我们的生活")
        XCTAssertEqual(parsed?.isFinal, false)
    }

    func testAllDefiniteUtterancesIsFinal() {
        let result: [String: Any] = [
            "text": "欢迎使用智音翻译，人工智能正在改变我们的生活。",
            "utterances": [["text": "欢迎使用智音翻译，人工智能正在改变我们的生活。", "definite": true, "start_time": 40, "end_time": 3560]]
        ]
        let parsed = VolcanoASRClient.parseASRResult(result)
        XCTAssertEqual(parsed?.isFinal, true)
    }

    func testEmptyUtterancesIsNotFinal() {
        // A message with text but no utterances must not be final
        // (allSatisfy on an empty list would otherwise say true).
        let result: [String: Any] = ["text": "欢迎"]
        XCTAssertEqual(VolcanoASRClient.parseASRResult(result)?.isFinal, false)
    }

    func testCumulativeTextReplacesNotAppends() {
        // Each message carries the full text so far; the parser just
        // passes it through, and the caller replaces the transcript.
        let first: [String: Any] = ["text": "欢迎", "utterances": [["definite": false]]]
        let second: [String: Any] = ["text": "欢迎使用", "utterances": [["definite": false]]]
        XCTAssertEqual(VolcanoASRClient.parseASRResult(first)?.text, "欢迎")
        XCTAssertEqual(VolcanoASRClient.parseASRResult(second)?.text, "欢迎使用")
    }
}
