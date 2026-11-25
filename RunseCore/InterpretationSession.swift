import Foundation
import SwiftData

/// A saved interpretation session: reviewable, with its segments.
/// Created by the interpretation page from the engine's
/// `InterpretationSessionRecord` when a session stops.
@Model public final class InterpretationSession {
    @Attribute(.unique) public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var directionRaw: String
    public var modeRaw: String
    /// Measured end-to-end latency (first TTS audio after the first
    /// audio packet), ms. Nil when nothing was measured.
    public var latencyMs: Double?
    @Relationship(deleteRule: .cascade) public var segments: [InterpretationSegmentRecord]

    public init(record: InterpretationSessionRecord) {
        self.id = UUID().uuidString
        self.startedAt = record.startedAt
        self.endedAt = record.endedAt
        self.directionRaw = record.direction.rawValue
        self.modeRaw = record.mode == .live ? "live" : "fallback"
        self.latencyMs = record.latency?.endToEndMs
        self.segments = record.segments.map { InterpretationSegmentRecord(segment: $0) }
    }

    public var directionTitle: String {
        switch directionRaw {
        case "zhToEn": return "中文 → 英文"
        case "enToZh": return "英文 → 中文"
        case "both": return "双向"
        default: return directionRaw
        }
    }

    public var modeTitle: String {
        modeRaw == "live" ? "实时同传" : "顺序语音线"
    }

    public var durationSeconds: Double {
        endedAt.timeIntervalSince(startedAt)
    }

    /// Plain-text export for sharing / review.
    public func exportedText() -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        lines.append("智音同传 \(formatter.string(from: startedAt))（\(directionTitle)，\(modeTitle)，\(Int(durationSeconds))秒）")
        for segment in segments.sorted(by: { $0.createdAt < $1.createdAt }) {
            if !segment.sourceText.isEmpty { lines.append("原文：\(segment.sourceText)") }
            if !segment.translationText.isEmpty { lines.append("译文：\(segment.translationText)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

@Model public final class InterpretationSegmentRecord {
    @Attribute(.unique) public var id: String
    public var directionRaw: String
    public var modeRaw: String
    public var sourceText: String
    public var translationText: String
    public var speakerChanged: Bool
    public var latencyMs: Double?
    public var createdAt: Date
    public var session: InterpretationSession?

    public init(segment: InterpretationSegment) {
        self.id = segment.id.uuidString
        self.directionRaw = segment.direction.rawValue
        self.modeRaw = segment.mode.rawValue
        self.sourceText = segment.sourceText
        self.translationText = segment.translationText
        self.speakerChanged = segment.speakerChanged
        self.latencyMs = segment.latencyMs
        self.createdAt = segment.createdAt
    }
}
