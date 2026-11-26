import RunseCore
import XCTest

final class SegmentationTests: XCTestCase {
    func testSplitsOnParagraphsAndSentences() {
        let text = "第一段第一句。第二段第一句！第二段第二句？"
        let segments = TextSegmenter.segments(for: text, maxChars: 800)
        XCTAssertEqual(segments, ["第一段第一句。第二段第一句！第二段第二句？"])
    }

    func testMergesShortSentencesUpToLimit() {
        let text = "甲。乙。丙。丁。"
        let segments = TextSegmenter.segments(for: text, maxChars: 6)
        XCTAssertEqual(segments, ["甲。乙。丙。", "丁。"])
    }

    func testHardSplitsOversizedSentence() {
        let text = String(repeating: "啊", count: 25)
        let segments = TextSegmenter.segments(for: text, maxChars: 10)
        XCTAssertEqual(segments, [String(repeating: "啊", count: 10), String(repeating: "啊", count: 10), String(repeating: "啊", count: 5)])
    }

    func testEnglishSentences() {
        let text = "Hello world. This is a test! Is it working?"
        let segments = TextSegmenter.segments(for: text, maxChars: 800)
        XCTAssertEqual(segments, [text])
    }

    // C1–C4: abbreviations and ellipsis mid-sentence must not split.
    func testAbbreviationsBeforeCapitalsDoNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("The U.S. Government announced new rules."),
            ["The U.S. Government announced new rules."]
        )
        XCTAssertEqual(
            TextSegmenter.splitSentences("He arrived at 9 a.m. Eastern Time."),
            ["He arrived at 9 a.m. Eastern Time."]
        )
        XCTAssertEqual(
            TextSegmenter.splitSentences("The meeting is at 3 p.m. Monday."),
            ["The meeting is at 3 p.m. Monday."]
        )
    }

    func testLatinAbbreviationsDoNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("Smith vs. Tyson was the main event."),
            ["Smith vs. Tyson was the main event."]
        )
        XCTAssertEqual(
            TextSegmenter.splitSentences("Bring fruit, e.g. Fuji apples."),
            ["Bring fruit, e.g. Fuji apples."]
        )
    }

    func testDegreesAndInitialsDoNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("She earned her Ph.D. in physics."),
            ["She earned her Ph.D. in physics."]
        )
        XCTAssertEqual(
            TextSegmenter.splitSentences("J. Smith arrived early."),
            ["J. Smith arrived early."]
        )
    }

    func testEllipsisDoesNotSplit() {
        XCTAssertEqual(
            TextSegmenter.splitSentences("He paused... then continued."),
            ["He paused... then continued."]
        )
        XCTAssertEqual(
            TextSegmenter.splitSentences("Wait... what happened?"),
            ["Wait... what happened?"]
        )
    }

    func testAmPmStillSplitsAtRealSentenceEnd() {
        // The guard above must not swallow a genuine sentence end.
        XCTAssertEqual(
            TextSegmenter.splitSentences("Mr. Smith arrived at 9 a.m. He was early."),
            ["Mr. Smith arrived at 9 a.m.", " He was early."]
        )
    }

    func testEmptyTextProducesNoSegments() {
        XCTAssertEqual(TextSegmenter.segments(for: "   \n  "), [])
    }

    func testLanguageDetection() {
        XCTAssertEqual(TextLanguage.detect("你好，世界。这是一个测试。"), .chinese)
        XCTAssertEqual(TextLanguage.detect("Hello world, this is a test."), .english)
        XCTAssertEqual(TextLanguage.detect("你好世界 Hello"), .chinese)
    }
}
