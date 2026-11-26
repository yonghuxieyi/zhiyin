import PDFKit
import RunseCore
import UIKit
import XCTest

/// Unit tests for the M12 PDF work: paragraph merging, per-page
/// character-range box lookup (no whole-document findString), and
/// the on-disk progress store for breakpoint resume. Live translation
/// itself needs real keys and is not covered here.
final class PDFTranslationTests: XCTestCase {

    private func line(_ text: String, x: CGFloat = 36, y: CGFloat, width: CGFloat = 500, height: CGFloat = 14) -> PDFTextLine {
        PDFTextLine(text: text, bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    private func page(lines: [PDFTextLine]) -> PDFPageContent {
        PDFPageContent(index: 0, lines: lines, isScanned: false, pageSize: CGSize(width: 612, height: 792))
    }

    // MARK: - Paragraph merging

    func testWrappedLinesWithoutTerminalPunctuationMerge() {
        // Two lines, normal line spacing (gap 4 < 0.4 * 14), first
        // line does not end a sentence: one paragraph.
        let content = page(lines: [line("这是第一行没有", y: 700), line("句号的长句子", y: 682)])
        let paras = content.paragraphs
        XCTAssertEqual(paras.count, 1)
        XCTAssertEqual(paras[0].text, "这是第一行没有句号的长句子")
    }

    func testWrappedEnglishLinesJoinWithSpace() {
        // N2: "The quick brown" + "fox jumps" must not become
        // "brownfox".
        let content = page(lines: [line("The quick brown", y: 700), line("fox jumps", y: 682)])
        let paras = content.paragraphs
        XCTAssertEqual(paras.count, 1)
        XCTAssertEqual(paras[0].text, "The quick brown fox jumps")
    }

    func testSentenceEndPlusWiderGapStartsNewParagraph() {
        // First line ends with 。 and the gap (10 > 0.4 * 14) is wider
        // than normal leading: new paragraph.
        let content = page(lines: [line("第一句结束了。", y: 700), line("第二句开始了。", y: 676)])
        XCTAssertEqual(content.paragraphs.count, 2)
    }

    func testBlankLineGapStartsNewParagraphEvenWithoutPunctuation() {
        // Gap 30 > 1.5 * 14: a blank line separates the paragraphs
        // even though the first line has no terminal punctuation.
        let content = page(lines: [line("上一段没写完", y: 700), line("下一段另起", y: 656)])
        XCTAssertEqual(content.paragraphs.count, 2)
    }

    func testSingleBlankLineSplitsParagraph() {
        // E2: one blank line means pitch 28 (2 x 14) but a gap of
        // only 14 (1 x 14). The old `gap > 1.5 x height` test never
        // fired on this, so paragraphs ran together.
        let content = page(lines: [line("上一段没写完", y: 700), line("下一段另起", y: 672)])
        XCTAssertEqual(content.paragraphs.count, 2)
    }

    func testUnknownBoxesFallBackToPunctuationOnly() {
        let content = page(lines: [
            PDFTextLine(text: "第一句。", bounds: .zero),
            PDFTextLine(text: "第二句。", bounds: .zero),
        ])
        XCTAssertEqual(content.paragraphs.count, 2)
        let wrapped = page(lines: [
            PDFTextLine(text: "第一行没", bounds: .zero),
            PDFTextLine(text: "完呢", bounds: .zero),
        ])
        XCTAssertEqual(wrapped.paragraphs.count, 1)
    }

    func testParagraphBoundsAreUnionOfLineBounds() {
        let content = page(lines: [line("上", y: 700, width: 100), line("下", y: 682, width: 200)])
        let para = content.paragraphs[0]
        XCTAssertEqual(para.bounds.minX, 36)
        XCTAssertEqual(para.bounds.maxX, 236)
        XCTAssertEqual(para.bounds.minY, 682)
        XCTAssertEqual(para.bounds.maxY, 714)
    }

    func testEndsSentenceIgnoresTrailingClosers() {
        XCTAssertTrue(PDFTranslation.endsSentence("他说：“你好。”"))
        XCTAssertTrue(PDFTranslation.endsSentence("真的吗？"))
        XCTAssertFalse(PDFTranslation.endsSentence("未完待续"))
        XCTAssertFalse(PDFTranslation.endsSentence("逗号，"))
    }

    // MARK: - Per-page box lookup (no whole-document findString)

    /// Builds a real two-page PDF in memory: page 1 has a repeated
    /// line, page 2 has the same text once. Extraction must find a
    /// non-zero box for every line on its own page.
    @MainActor
    func testExtractPagesFindsBoxesPerPage() async {
        let data = makeTwoPagePDF()
        let document = PDFDocument(data: data)
        XCTAssertNotNil(document)
        let pages = await PDFTranslation.extractPages(from: document!)
        XCTAssertEqual(pages.count, 2)
        for content in pages {
            XCTAssertFalse(content.lines.isEmpty)
            for pdfLine in content.lines {
                XCTAssertNotEqual(pdfLine.bounds, .zero, "line '\(pdfLine.text)' on page \(content.index) has no box")
            }
        }
        // The repeated line on page 1 resolves to two distinct boxes
        // (running search offset), not the same box twice.
        let repeated = pages[0].lines.filter { $0.text == "重复行" }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertNotEqual(repeated[0].bounds, repeated[1].bounds)
    }

    private func makeTwoPagePDF() -> Data {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        return renderer.pdfData { context in
            context.beginPage()
            ("第一行" as NSString).draw(at: CGPoint(x: 36, y: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            ("重复行" as NSString).draw(at: CGPoint(x: 36, y: 56), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            ("重复行" as NSString).draw(at: CGPoint(x: 36, y: 76), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            context.beginPage()
            ("重复行" as NSString).draw(at: CGPoint(x: 36, y: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }

    // MARK: - Progress store

    func testProgressStoreRoundTrip() throws {
        let hash = "m12-test-\(UUID().uuidString)"
        let tpage = PDFTranslatedPage(
            index: 0,
            paragraphs: [
                PDFTranslatedParagraph(source: "你好", translation: "Hello", bounds: CGRect(x: 0, y: 0, width: 100, height: 14)),
                PDFTranslatedParagraph(source: "失败段", translation: "失败段", bounds: .zero, failed: true),
            ],
            isScanned: false,
            pageSize: CGSize(width: 612, height: 792)
        )
        try PDFProgressStore.save(hash: hash, fileName: "test.pdf", pageCount: 3, pages: [tpage])
        defer { PDFProgressStore.delete(hash: hash) }
        let loaded = PDFProgressStore.load(hash: hash, pageCount: 3)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.pages.count, 1)
        XCTAssertEqual(loaded?.pages[0].paragraphs[0].translation, "Hello")
        XCTAssertEqual(loaded?.pages[0].paragraphs[1].failed, true)
        // A page-count mismatch means stale progress: ignored.
        XCTAssertNil(PDFProgressStore.load(hash: hash, pageCount: 99))
    }
}
