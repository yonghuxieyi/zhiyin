import CryptoKit
import Foundation
import PDFKit
import UIKit

/// PDF document translation (清单 11, M12): import, extract text per
/// page (scanned pages go through Vision OCR), merge adjacent lines
/// into paragraphs (line spacing + sentence-final punctuation),
/// translate paragraph by paragraph with the glossary kept
/// consistent, show progress, and export a translated PDF.
///
/// A paragraph that fails to translate keeps its original text with
/// a failure mark and the run continues; translated pages are
/// persisted to disk as they finish so translation can resume from
/// the breakpoint.
///
/// Export, two paths:
/// - Text pages with known line boxes: the original page is drawn into
///   the new PDF (vectors and images preserved — the page is replayed,
///   not rasterized), the original text is covered with a white rect,
///   and the translation is drawn in its place with the font shrunk
///   until it fits the box.
/// - Scanned pages, or pages whose line boxes could not be found:
///   simplified layout — the page rendered as an image on top, the
///   translation below, paginated as needed. Keeping the scanned
///   layout is a later step.
///
/// The export math is written to be correct by construction
/// (explicit flip for the PDF page draw, UIKit coordinates for text),
/// but the visual result has NOT been verified on a real device yet —
/// the first exported PDF must be eyeballed before trusting the
/// layout.
public struct PDFTextLine: Sendable, Equatable {
    public var text: String
    /// Line box in PDF page coordinates (origin bottom-left). `.zero`
    /// when the box could not be found (page falls back to simplified
    /// layout).
    public var bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// One paragraph on a page: the source lines merged by the M12
/// rule below, with the union of their boxes. The translation unit
/// is the paragraph, not the line.
public struct PDFParagraph: Sendable, Equatable {
    public var text: String
    public var lines: [PDFTextLine]
    /// Union of the line boxes (`.zero` when no line had a box).
    public var bounds: CGRect

    public init(text: String, lines: [PDFTextLine]) {
        self.text = text
        self.lines = lines
        // Only real boxes count: a `.zero` (unknown) box must not drag
        // the union out to the origin.
        let boxes = lines.map(\.bounds).filter { $0 != .zero }
        self.bounds = boxes.reduce(CGRect.null) { $0.union($1) }
        if self.bounds.isNull { self.bounds = .zero }
    }
}

public struct PDFPageContent: Sendable {
    public var index: Int
    public var lines: [PDFTextLine]
    public var isScanned: Bool
    public var pageSize: CGSize

    public init(index: Int, lines: [PDFTextLine], isScanned: Bool, pageSize: CGSize) {
        self.index = index
        self.lines = lines
        self.isScanned = isScanned
        self.pageSize = pageSize
    }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// M12: merge adjacent lines into paragraphs. Lines are in
    /// top-to-bottom reading order (PDF coordinates: origin
    /// bottom-left, so the upper line has the larger y).
    ///
    /// A new paragraph starts when:
    /// - the previous line ends with sentence-final punctuation
    ///   (。！？!?…；;) AND the vertical gap to the next line is
    ///   wider than normal line spacing (> 0.4 × line height), or
    /// - the vertical gap is blank-line sized (> 1.5 × line height).
    /// When either box is unknown (`.zero`) only the punctuation rule
    /// applies, so a wrapped sentence is never split by a missing box.
    public var paragraphs: [PDFParagraph] {
        guard !lines.isEmpty else { return [] }
        var result: [PDFParagraph] = []
        var current: [PDFTextLine] = [lines[0]]
        for line in lines.dropFirst() {
            let prev = current.last!
            if startsNewParagraph(after: prev, next: line) {
                result.append(PDFParagraph(text: current.map(\.text).joined(), lines: current))
                current = [line]
            } else {
                current.append(line)
            }
        }
        result.append(PDFParagraph(text: current.map(\.text).joined(), lines: current))
        return result
    }

    private func startsNewParagraph(after prev: PDFTextLine, next: PDFTextLine) -> Bool {
        let endsSentence = PDFTranslation.endsSentence(prev.text)
        let prevBox = prev.bounds
        let nextBox = next.bounds
        guard prevBox != .zero, nextBox != .zero, prevBox.height > 0 else {
            // No geometry to judge spacing by — punctuation alone.
            return endsSentence
        }
        // Gap between the bottom of the upper line and the top of the
        // lower line (PDF coords grow upwards).
        let gap = prevBox.minY - nextBox.maxY
        let lineHeight = prevBox.height
        if gap > lineHeight * 1.5 { return true }
        if endsSentence && gap > lineHeight * 0.4 { return true }
        return false
    }
}

/// One translated paragraph. `failed` means the translation call
/// failed and `translation` is the original text, kept so the run
/// could continue — the UI marks it and the user can retry it later.
/// `check` is the dual-model verdict; it is not persisted (it can be
/// re-run), so Codable skips it.
public struct PDFTranslatedParagraph: Sendable, Equatable, Codable {
    public var source: String
    public var translation: String
    public var bounds: CGRect
    public var failed: Bool
    public var check: DualModelCompare.Verdict?

    public init(source: String, translation: String, bounds: CGRect, failed: Bool = false, check: DualModelCompare.Verdict? = nil) {
        self.source = source
        self.translation = translation
        self.bounds = bounds
        self.failed = failed
        self.check = check
    }

    enum CodingKeys: String, CodingKey {
        case source, translation, bounds, failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        translation = try container.decode(String.self, forKey: .translation)
        bounds = try container.decode(CGRect.self, forKey: .bounds)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        check = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(translation, forKey: .translation)
        try container.encode(bounds, forKey: .bounds)
        try container.encode(failed, forKey: .failed)
    }
}

public struct PDFTranslatedPage: Sendable, Codable {
    public var index: Int
    public var paragraphs: [PDFTranslatedParagraph]
    public var isScanned: Bool
    public var pageSize: CGSize

    public init(index: Int, paragraphs: [PDFTranslatedParagraph], isScanned: Bool, pageSize: CGSize) {
        self.index = index
        self.paragraphs = paragraphs
        self.isScanned = isScanned
        self.pageSize = pageSize
    }

    public var plainTranslation: String {
        paragraphs.map(\.translation).joined(separator: "\n\n")
    }
}

/// Persists translated PDF pages to disk so a translation can resume
/// from its breakpoint after a failure, a cancellation, or the app
/// being killed. One file per document, keyed by the SHA-256 of the
/// document data.
public enum PDFProgressStore {
    public struct SavedProgress: Codable {
        public var fileName: String
        public var pageCount: Int
        public var pages: [PDFTranslatedPage]
        public var savedAt: Date
    }

    public static func documentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func progressURL(forHash hash: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Zhiyin/PDFProgress", isDirectory: true)
        return dir.appendingPathComponent("\(hash).json")
    }

    public static func save(hash: String, fileName: String, pageCount: Int, pages: [PDFTranslatedPage]) throws {
        let url = progressURL(forHash: hash)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let progress = SavedProgress(fileName: fileName, pageCount: pageCount, pages: pages, savedAt: Date())
        let data = try JSONEncoder().encode(progress)
        try data.write(to: url, options: .atomic)
    }

    /// Returns the saved progress only when it matches this document
    /// (same page count); otherwise nil (stale progress is ignored).
    public static func load(hash: String, pageCount: Int) -> SavedProgress? {
        guard let data = try? Data(contentsOf: progressURL(forHash: hash)),
              let progress = try? JSONDecoder().decode(SavedProgress.self, from: data),
              progress.pageCount == pageCount else { return nil }
        return progress
    }

    public static func delete(hash: String) {
        try? FileManager.default.removeItem(at: progressURL(forHash: hash))
    }
}

public enum PDFTranslation {
    /// Extracts one content record per page. A page counts as scanned
    /// when PDFKit finds no text on it; scanned pages are rendered and
    /// OCR'd with Vision (on device).
    ///
    /// Main-actor isolated on purpose: the caller hands over its
    /// `@State PDFDocument`, which must not cross to nonisolated code.
    /// Sentence-final punctuation, shared by the paragraph merge
    /// and the segmenter. Trailing closing quotes/brackets are
    /// ignored when judging the end of a line.
    public static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["」", "』", "”", "’", "）", ")", "]", "】"]
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while let last = trimmed.last, closers.contains(last) {
            trimmed.removeLast()
        }
        guard let last = trimmed.last else { return false }
        return ["。", "！", "？", "!", "?", "…", "；", ";"].contains(last)
    }

    @MainActor
    public static func extractPages(from document: PDFDocument) async -> [PDFPageContent] {
        var result: [PDFPageContent] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let size = page.bounds(for: .mediaBox).size
            let rawText = page.string ?? ""
            let textLines = rawText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if textLines.isEmpty {
                let ocrLines = await ocrPage(page, size: size)
                result.append(PDFPageContent(index: index, lines: ocrLines, isScanned: true, pageSize: size))
                continue
            }
            var lines: [PDFTextLine] = []
            // M12: locate each line on THIS page only, by character
            // range — the old whole-document findString could return a
            // match on a different page (or the wrong occurrence of a
            // repeated line). The running search offset maps repeated
            // lines to successive occurrences in reading order.
            var searchFrom = rawText.startIndex
            for line in textLines {
                let bounds = box(for: line, on: page, in: rawText, searchFrom: &searchFrom) ?? .zero
                lines.append(PDFTextLine(text: line, bounds: bounds))
            }
            result.append(PDFPageContent(index: index, lines: lines, isScanned: false, pageSize: size))
        }
        return result
    }

    /// Finds `line` in the page's own text starting at `searchFrom`
    /// (advancing it past the match), then asks the page for the
    /// selection covering exactly that character range and returns
    /// its bounds in page coordinates, or nil when not found.
    private static func box(for line: String, on page: PDFPage, in rawText: String, searchFrom: inout String.Index) -> CGRect? {
        guard let range = rawText.range(of: line, range: searchFrom..<rawText.endIndex) else { return nil }
        searchFrom = range.upperBound
        let nsRange = NSRange(range, in: rawText)
        guard let selection = page.selection(for: nsRange) else { return nil }
        let bounds = selection.bounds(for: page)
        guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// Renders a scanned page and OCRs it. Boxes are converted from
    /// Vision's normalized top-left coordinates to PDF page
    /// coordinates (origin bottom-left). Main-actor isolated: it only
    /// runs from `extractPages`, which hands it a main-actor page.
    @MainActor
    private static func ocrPage(_ page: PDFPage, size: CGSize) async -> [PDFTextLine] {
        let scale: CGFloat = 2
        let renderSize = CGSize(width: size.width * scale, height: size.height * scale)
        let image = page.thumbnail(of: renderSize, for: .mediaBox)
        guard let cgImage = image.cgImage else { return [] }
        let lines = (try? await VisionTextRecognizer.recognizeText(in: cgImage)) ?? []
        return lines.map { line in
            let box = line.boundingBox
            let pdfRect = CGRect(
                x: box.minX * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            )
            return PDFTextLine(text: line.text, bounds: pdfRect)
        }
    }

    /// Renders a page to an image (used by the simplified export).
    public static func renderPage(_ page: PDFPage, maxWidth: CGFloat = 1200) -> UIImage {
        let size = page.bounds(for: .mediaBox).size
        let scale = min(2, maxWidth / max(size.width, 1))
        return page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
    }

    // MARK: - Export

    /// Builds the translated PDF. Returns nil when there is nothing to
    /// export. Pages with line boxes use the in-place path; scanned
    /// pages (and pages without boxes) use the simplified path.
    public static func exportPDF(original: PDFDocument, translatedPages: [PDFTranslatedPage]) -> Data? {
        guard !translatedPages.isEmpty else { return nil }
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        return renderer.pdfData { context in
            for tpage in translatedPages {
                guard let originalPage = original.page(at: tpage.index) else { continue }
                let pageSize = tpage.pageSize
                let canDoInPlace = !tpage.isScanned && tpage.paragraphs.allSatisfy { $0.bounds != .zero }
                if canDoInPlace {
                    context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                    drawOriginalPage(originalPage, pageSize: pageSize, in: context.cgContext)
                    for paragraph in tpage.paragraphs {
                        drawTranslatedParagraph(paragraph, pageSize: pageSize, in: context.cgContext)
                    }
                } else {
                    drawSimplifiedPage(originalPage: originalPage, tpage: tpage, in: context)
                }
            }
        }
    }

    /// Draws the original page into the new PDF, vectors and images
    /// preserved. The renderer context is UIKit-flipped, so the page
    /// is drawn with an explicit flip back to PDF coordinates.
    private static func drawOriginalPage(_ page: PDFPage, pageSize: CGSize, in context: CGContext) {
        guard let pdfPage = page.pageRef else { return }
        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.drawPDFPage(pdfPage)
        context.restoreGState()
    }

    /// Covers the original paragraph with white and draws the
    /// translation in its place. A paragraph spans several source
    /// lines, so the text wraps inside the union box and the font
    /// shrinks until the wrapped text fits both width and height
    /// (minimum 6 pt). Coordinates are UIKit (top-left origin):
    /// the PDF box is flipped vertically.
    private static func drawTranslatedParagraph(_ paragraph: PDFTranslatedParagraph, pageSize: CGSize, in context: CGContext) {
        let box = paragraph.bounds
        guard box.width > 0, box.height > 0 else { return }
        // PDF coords (bottom-left) -> UIKit coords (top-left).
        let uiRect = CGRect(x: box.minX, y: pageSize.height - box.maxY, width: box.width, height: box.height)
        // Cover the original text. A small inset keeps neighbouring
        // paragraphs untouched.
        let cover = uiRect.insetBy(dx: -1, dy: -1)
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(cover)
        context.restoreGState()
        // Fit the font: start from the line height, shrink until the
        // wrapped text fits the box.
        var fontSize = min(box.height * 0.8, 16)
        let text = paragraph.translation as NSString
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
        ]
        while fontSize > 6 {
            let size = text.boundingRect(
                with: CGSize(width: uiRect.width - 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil
            ).size
            if size.height <= uiRect.height { break }
            fontSize -= 0.5
            attributes[.font] = UIFont.systemFont(ofSize: fontSize)
        }
        text.draw(
            with: uiRect.insetBy(dx: 1, dy: 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil
        )
    }

    /// Simplified page: the original page as an image on top, the
    /// translation as flowing text below, paginated as needed.
    private static func drawSimplifiedPage(originalPage: PDFPage, tpage: PDFTranslatedPage, in context: UIGraphicsPDFRendererContext) {
        let pageSize = tpage.pageSize
        let image = renderPage(originalPage, maxWidth: 1000)
        let imageAspect = image.size.height / max(image.size.width, 1)
        let imageHeight = min(pageSize.height * 0.45, pageSize.width * imageAspect)
        let fontSize: CGFloat = 12
        let font = UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let text = tpage.plainTranslation as NSString
        let textWidth = pageSize.width - 72
        // Split the translation into page-sized chunks by measuring.
        var remaining = text as String
        var isFirstPage = true
        while !remaining.isEmpty || isFirstPage {
            context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
            let textY: CGFloat
            if isFirstPage {
                let imageRect = CGRect(x: 36, y: 36, width: pageSize.width - 72, height: imageHeight)
                image.draw(in: imageRect)
                textY = 36 + imageHeight + 16
                isFirstPage = false
            } else {
                textY = 36
            }
            let availableHeight = pageSize.height - textY - 36
            let textRect = CGRect(x: 36, y: textY, width: textWidth, height: availableHeight)
            let fitting = fittingPrefix(of: remaining, in: textRect, attributes: attributes)
            (fitting as NSString).draw(in: textRect, withAttributes: attributes)
            if fitting.count >= remaining.count { break }
            remaining = String(remaining.dropFirst(fitting.count))
        }
    }

    /// Returns the longest prefix of `text` that fits in `rect` at the
    /// given attributes (word-boundary aware).
    private static func fittingPrefix(of text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) -> String {
        let full = text as NSString
        let fullSize = full.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        guard fullSize.height > rect.height else { return text }
        // Binary search the character count that fits.
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            let prefix = String(text.prefix(mid)) as NSString
            let size = prefix.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            if size.height <= rect.height {
                low = mid
            } else {
                high = mid - 1
            }
        }
        var fitting = String(text.prefix(low))
        // Back off to a word boundary so we never split a word.
        if fitting.count < text.count,
           let lastSpace = fitting.lastIndex(of: " ") ?? fitting.lastIndex(of: "\n") {
            fitting = String(fitting[..<lastSpace])
        }
        return fitting.isEmpty ? String(text.prefix(max(low, 1))) : fitting
    }
}
