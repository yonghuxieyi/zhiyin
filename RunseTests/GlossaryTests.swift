import RunseCore
import XCTest

final class GlossaryTests: XCTestCase {
    func testExtractsRepeatedChineseTerms() {
        let text = "人工智能正在改变世界，人工智能已经进入千家万户。人工智能的发展速度很快。"
        let candidates = GlossaryExtractor.candidates(from: text)
        let terms = candidates.map(\.term)
        XCTAssertTrue(terms.contains("人工智能"))
    }

    func testExtractsRepeatedEnglishTerms() {
        let text = "The transformer model is powerful. Many teams use the transformer model for translation."
        let candidates = GlossaryExtractor.candidates(from: text)
        let terms = candidates.map(\.term)
        XCTAssertTrue(terms.contains("transformer"))
    }

    func testIgnoresSingleOccurrences() {
        let text = "这是一个独特的词，只出现一次。其他内容完全不同。"
        let candidates = GlossaryExtractor.candidates(from: text)
        XCTAssertFalse(candidates.map(\.term).contains("独特"))
    }

    func testGlossaryPromptBlock() {
        let filled = GlossaryEntry(sourceTerm: "人工智能", targetTranslation: "artificial intelligence")
        let empty = GlossaryEntry(sourceTerm: "大模型", targetTranslation: "")
        let block = GlossaryPrompt.block(for: [filled, empty])
        XCTAssertTrue(block.contains("人工智能 -> artificial intelligence"))
        XCTAssertFalse(block.contains("大模型"))
        XCTAssertEqual(GlossaryPrompt.block(for: [empty]), "")
    }
}
