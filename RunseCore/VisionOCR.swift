import Foundation
import Vision

/// On-device text recognition for photos and images. Uses Apple's Vision
/// framework (`VNRecognizeTextRequest`) with accurate recognition for
/// Chinese; nothing leaves the device. Photo and camera input share this
/// one module.
public enum VisionTextRecognizer {
    public struct Line: Sendable, Equatable {
        public var text: String
        /// Normalized bounding box in image coordinates (origin top-left).
        public var boundingBox: CGRect

        public init(text: String, boundingBox: CGRect) {
            self.text = text
            self.boundingBox = boundingBox
        }
    }

    public enum RecognizerError: Error, LocalizedError {
        case noTextFound

        public var errorDescription: String? {
            switch self {
            case .noTextFound: "No text was found in this image."
            }
        }
    }

    /// Recognizes text in an image, returning lines in reading order
    /// (top to bottom, left to right).
    public static func recognizeText(in image: CGImage) async throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observations = request.results, !observations.isEmpty else {
            throw RecognizerError.noTextFound
        }
        let lines = observations.compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // Vision boxes use a bottom-left origin; flip to top-left.
            let box = observation.boundingBox
            let flipped = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            return Line(text: text, boundingBox: flipped)
        }
        return lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.02 {
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    /// The recognized lines joined into plain text, one line per row.
    public static func plainText(from lines: [Line]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}
