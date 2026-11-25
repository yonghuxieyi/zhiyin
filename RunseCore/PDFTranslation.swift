import Foundation
import PDFKit
import UIKit

/// PDF document translation (清单 11): import, extract text per page
/// (scanned pages go through Vision OCR), translate segment by segment
/// with the glossary kept consistent, show progress, and export a
/// translated PDF.
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
}

public struct PDFTranslatedLine: Sendable, Equatable {
    public var source: String
    public var translation: String
    public var bounds: CGRect
    public var check: DualModelCompare.Verdict?

    public init(source: String, translation: String, bounds: CGRect, check: DualModelCompare.Verdict? = nil) {
        self.source = source
        self.translation = translation
        self.bounds = bounds
        self.check = check
    }
}

public struct PDFTranslatedPage: Sendable {
    public var index: Int
    public var lines: [PDFTranslatedLine]
    public var isScanned: Bool
    public var pageSize: CGSize

    public init(index: Int, lines: [PDFTranslatedLine], isScanned: Bool, pageSize: CGSize) {
        self.index = index
        self.lines = lines
        self.isScanned = isScanned
        self.pageSize = pageSize
    }

    public var plainTranslation: String {
        lines.map(\.translation).joined(separator: "\n")
    }
}

public enum PDFTranslation {
    /// Extracts one content record per page. A page counts as scanned
    /// when PDFKit finds no text on it; scanned pages are rendered and
    /// OCR'd with Vision (on device).
    ///
    /// Main-actor isolated on purpose: the caller hands over its
    /// `@State PDFDocument`, which must not cross to nonisolated code.
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
            for line in textLines {
                let bounds = box(for: line, on: page, in: document) ?? .zero
                lines.append(PDFTextLine(text: line, bounds: bounds))
            }
            result.append(PDFPageContent(index: index, lines: lines, isScanned: false, pageSize: size))
        }
        return result
    }

    /// Finds the first selection of `line` on `page` and returns its
    /// bounds in page coordinates, or nil when not found.
    private static func box(for line: String, on page: PDFPage, in document: PDFDocument) -> CGRect? {
        let selections = document.findString(line, withOptions: [.caseInsensitive])
        for selection in selections {
            guard selection.pages.contains(page) else { continue }
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else { continue }
            return bounds
        }
        return nil
    }

    /// Renders a scanned page and OCRs it. Boxes are converted from
    /// Vision's normalized top-left coordinates to PDF page
    /// coordinates (origin bottom-left).
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
                let canDoInPlace = !tpage.isScanned && tpage.lines.allSatisfy { $0.bounds != .zero }
                if canDoInPlace {
                    context.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                    drawOriginalPage(originalPage, pageSize: pageSize, in: context.cgContext)
                    for line in tpage.lines {
                        drawTranslatedLine(line, pageSize: pageSize, in: context.cgContext)
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

    /// Covers the original line with white and draws the translation
    /// in its place, shrinking the font until it fits the box
    /// (minimum 6 pt). Coordinates are UIKit (top-left origin):
    /// the PDF box is flipped vertically.
    private static func drawTranslatedLine(_ line: PDFTranslatedLine, pageSize: CGSize, in context: CGContext) {
        let box = line.bounds
        guard box.width > 0, box.height > 0 else { return }
        // PDF coords (bottom-left) -> UIKit coords (top-left).
        let uiRect = CGRect(x: box.minX, y: pageSize.height - box.maxY, width: box.width, height: box.height)
        // Cover the original text. A small inset keeps neighbouring
        // lines untouched.
        let cover = uiRect.insetBy(dx: -1, dy: -1)
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(cover)
        context.restoreGState()
        // Fit the font: start from the line height, shrink to fit.
        var fontSize = min(box.height * 0.8, 16)
        let text = line.translation as NSString
        var attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize)]
        while fontSize > 6 {
            let size = text.size(withAttributes: attributes)
            if size.width <= box.width - 2 { break }
            fontSize -= 0.5
            attributes[.font] = UIFont.systemFont(ofSize: fontSize)
        }
        let textHeight = text.size(withAttributes: attributes).height
        let drawRect = CGRect(
            x: uiRect.minX,
            y: uiRect.minY + (uiRect.height - textHeight) / 2,
            width: uiRect.width,
            height: textHeight
        )
        text.draw(in: drawRect, withAttributes: attributes)
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
