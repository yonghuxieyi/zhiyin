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

    func testEmptyTextProducesNoSegments() {
        XCTAssertEqual(TextSegmenter.segments(for: "   \n  "), [])
    }

    func testLanguageDetection() {
        XCTAssertEqual(TextLanguage.detect("你好，世界。这是一个测试。"), .chinese)
        XCTAssertEqual(TextLanguage.detect("Hello world, this is a test."), .english)
        XCTAssertEqual(TextLanguage.detect("你好世界 Hello"), .chinese)
    }
}
