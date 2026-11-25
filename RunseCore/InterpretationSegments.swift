import Foundation

/// One interpreted sentence on the interpretation page: source text
/// and its translation, paired by arrival order, with timing and the
/// path that produced it.
public struct InterpretationSegment: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable {
        case zhToEn
        case enToZh
    }

    public enum Mode: String, Sendable {
        /// Live Seed-LiveInterpret session.
        case live
        /// Sequential fallback: ASR → DeepSeek → TTS.
        case fallback
    }

    public var id: UUID
    public var direction: Direction
    public var mode: Mode
    /// Milliseconds relative to the session, from the service.
    public var sourceStartMs: Int64?
    public var sourceEndMs: Int64?
    public var translationStartMs: Int64?
    public var translationEndMs: Int64?
    public var sourceText: String
    public var translationText: String
    public var speakerChanged: Bool
    /// Latency of this sentence: first translation text after the
    /// source sentence started, ms (live path only).
    public var latencyMs: Double?
    /// Wall-clock creation time, for ordering segments across
    /// directions and modes.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        direction: Direction,
        mode: Mode,
        sourceStartMs: Int64? = nil,
        sourceEndMs: Int64? = nil,
        translationStartMs: Int64? = nil,
        translationEndMs: Int64? = nil,
        sourceText: String = "",
        translationText: String = "",
        speakerChanged: Bool = false,
        latencyMs: Double? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.direction = direction
        self.mode = mode
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.translationStartMs = translationStartMs
        self.translationEndMs = translationEndMs
        self.sourceText = sourceText
        self.translationText = translationText
        self.speakerChanged = speakerChanged
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }

    /// Both sides settled.
    public var isComplete: Bool { !sourceText.isEmpty && !translationText.isEmpty }
}

/// Assembles live subtitle events into segments. Pure state machine,
/// unit-tested.
///
/// Rules (from the AST v2 event model):
/// - `*SubtitleResponse` carries the current text of the sentence in
///   progress: it replaces the draft, never appends. A speaker who
///   corrects and re-says a sentence therefore overwrites the draft.
/// - `*SubtitleEnd` settles the sentence: the draft becomes the
///   segment text. Source and translation settle independently and
///   are paired by order (nth source sentence with nth translation).
/// - `spk_chg` arrives on the Start events (SourceSubtitleStart /
///   TranslationSubtitleStart): a new speaker opens a new segment,
///   so a new speaker never merges into the previous sentence. It
///   is also honored on End events when the server sets it there.
/// - Fallback sentences are appended directly with
///   `appendFallback(source:translation:)`.
public struct InterpretationSegmentAssembler: Sendable {
    public private(set) var segments: [InterpretationSegment] = []
    private var sourceDraft = ""
    private var translationDraft = ""
    private var direction: InterpretationSegment.Direction
    private var mode: InterpretationSegment.Mode
    private var sessionStart: Date
    /// Wall-clock time the current source sentence started, for the
    /// per-sentence latency sample.
    private var sourceSentenceStartedAt: Date?
    /// Set by a Start event with spk_chg; applied to the next
    /// appended segment, then cleared.
    private var pendingSpeakerChanged = false

    public init(direction: InterpretationSegment.Direction, mode: InterpretationSegment.Mode = .live, sessionStart: Date = .now) {
        self.direction = direction
        self.mode = mode
        self.sessionStart = sessionStart
    }

    public mutating func apply(_ event: LiveInterpretClient.Event) {
        switch event {
        case .sourceStarted(let speakerChanged):
            // A new speaker's sentence replaces the draft on the next
            // partial; the flag only marks the next settled segment.
            if speakerChanged { pendingSpeakerChanged = true }
        case .sourcePartial(let text):
            if sourceDraft.isEmpty && sourceSentenceStartedAt == nil {
                sourceSentenceStartedAt = .now
            }
            sourceDraft = text
        case .sourceFinal(let text, let startMs, let endMs, let speakerChanged):
            sourceDraft = ""
            let latency = sourceSentenceStartedAt.map { Date().timeIntervalSince($0) * 1000 }
            sourceSentenceStartedAt = nil
            appendSource(text: text, startMs: startMs, endMs: endMs, speakerChanged: speakerChanged || pendingSpeakerChanged, latencyMs: latency)
            pendingSpeakerChanged = false
        case .translationStarted(let speakerChanged):
            if speakerChanged { pendingSpeakerChanged = true }
        case .translationPartial(let text):
            translationDraft = text
        case .translationFinal(let text, let startMs, let endMs, let speakerChanged):
            translationDraft = ""
            appendTranslation(text: text, startMs: startMs, endMs: endMs, speakerChanged: speakerChanged || pendingSpeakerChanged)
            pendingSpeakerChanged = false
        case .sessionStarted, .ttsAudio, .ttsSentenceStarted, .ttsSentenceEnded, .muted, .usage, .sessionFinished, .failed:
            break
        }
    }

    /// Appends a finished fallback sentence (source + translation
    /// arrive together on the sequential path).
    public mutating func appendFallback(source: String, translation: String, latencyMs: Double? = nil) {
        segments.append(InterpretationSegment(
            direction: direction,
            mode: .fallback,
            sourceText: source,
            translationText: translation,
            latencyMs: latencyMs
        ))
    }

    /// The current in-progress drafts, for the live transcript view.
    public var liveDraft: (source: String, translation: String) {
        (sourceDraft, translationDraft)
    }

    private mutating func appendSource(text: String, startMs: Int64, endMs: Int64, speakerChanged: Bool, latencyMs: Double?) {
        // Pair with the earliest segment that still lacks source text.
        if let index = segments.firstIndex(where: { $0.translationText.isEmpty == false && $0.sourceText.isEmpty }) {
            segments[index].sourceText = text
            segments[index].sourceStartMs = startMs
            segments[index].sourceEndMs = endMs
            segments[index].speakerChanged = segments[index].speakerChanged || speakerChanged
            segments[index].latencyMs = latencyMs
            return
        }
        segments.append(InterpretationSegment(
            direction: direction,
            mode: mode,
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            sourceText: text,
            speakerChanged: speakerChanged,
            latencyMs: latencyMs
        ))
    }

    private mutating func appendTranslation(text: String, startMs: Int64, endMs: Int64, speakerChanged: Bool) {
        // Pair with the earliest segment that still lacks translation.
        if let index = segments.firstIndex(where: { $0.sourceText.isEmpty == false && $0.translationText.isEmpty }) {
            segments[index].translationText = text
            segments[index].translationStartMs = startMs
            segments[index].translationEndMs = endMs
            segments[index].speakerChanged = segments[index].speakerChanged || speakerChanged
            return
        }
        segments.append(InterpretationSegment(
            direction: direction,
            mode: mode,
            translationStartMs: startMs,
            translationEndMs: endMs,
            translationText: text,
            speakerChanged: speakerChanged
        ))
    }
}
