import Foundation

/// Latency budget for simultaneous interpretation, against the
/// boss's bar: ~2.5s target, 3s hard limit.
///
/// The pipeline stages overlap in streaming: the service starts
/// translating before the utterance ends, and the network round
/// trip overlaps with service processing. So the honest end-to-end
/// figure is `service + playback`, not the sum of every stage.
/// The non-overlapped worst case (chunk + network + service +
/// playback) is kept as the upper bound.
///
/// Documented numbers (2026-11-25):
/// - Service S2S latency: 2.53s (Seed-LiveInterpret 2.0 docs).
/// - Audio packets: 80ms (docs recommend 80ms per packet).
/// - Network and playback buffer: assumed upper bounds, unmeasured
///   on device; the engine replaces them with measured values at
///   runtime (first translation text / first TTS audio).
public struct LatencyBudget: Sendable, Equatable {
    /// Target end-to-end latency (boss's bar).
    public static let targetMs: Double = 2500
    /// Hard limit (boss's bar).
    public static let limitMs: Double = 3000

    /// One audio packet, ms.
    public var chunkMs: Double = 80
    /// Network round trip to the service, ms (assumed upper bound).
    public var networkMs: Double = 150
    /// Service S2S latency, ms (documented 2.53s).
    public var serviceMs: Double = 2530
    /// Playback buffer before the first audio reaches the ear, ms.
    /// 100 ms: the streaming TTS player starts on the first PCM chunk
    /// instead of waiting for a whole MP3, so the buffer can be smaller.
    public var playbackMs: Double = 100

    public init(chunkMs: Double = 80, networkMs: Double = 150, serviceMs: Double = 2530, playbackMs: Double = 100) {
        self.chunkMs = chunkMs
        self.networkMs = networkMs
        self.serviceMs = serviceMs
        self.playbackMs = playbackMs
    }

    /// Streaming (pipelined) end-to-end latency: service + playback.
    public var pipelinedMs: Double { serviceMs + playbackMs }

    /// Non-overlapped worst case: every stage back to back.
    public var worstCaseMs: Double { chunkMs + networkMs + serviceMs + playbackMs }

    public var meetsTarget: Bool { pipelinedMs <= Self.targetMs }
    public var withinLimit: Bool { worstCaseMs <= Self.limitMs }

    /// One measured end-to-end sample from a live session.
    public struct Measurement: Sendable, Equatable {
        /// First translation text after the first audio packet, ms.
        public var firstTranslationTextMs: Double?
        /// First TTS audio after the first audio packet, ms.
        public var firstTTSAudioMs: Double?
        /// Session start to first translation text, ms.
        public var sessionStartToFirstTranslationMs: Double?

        public init(
            firstTranslationTextMs: Double? = nil,
            firstTTSAudioMs: Double? = nil,
            sessionStartToFirstTranslationMs: Double? = nil
        ) {
            self.firstTranslationTextMs = firstTranslationTextMs
            self.firstTTSAudioMs = firstTTSAudioMs
            self.sessionStartToFirstTranslationMs = sessionStartToFirstTranslationMs
        }

        public var endToEndMs: Double? { firstTTSAudioMs ?? firstTranslationTextMs }

        public var meetsTarget: Bool {
            guard let endToEndMs else { return false }
            return endToEndMs <= LatencyBudget.targetMs
        }

        public var withinLimit: Bool {
            guard let endToEndMs else { return false }
            return endToEndMs <= LatencyBudget.limitMs
        }
    }
}

/// Glossary handling for the live path: builds the ordered
/// `corpus.glossary_list` pairs from the user's entries, and the
/// post-check used on the sequential fallback path (where the
/// glossary is enforced by prompt injection, not by the service).
public enum GlossaryAST {
    /// The service caps all corpus fields at 1000 items total
    /// (hot words + glossary + corrections). Keep the list short and
    /// deterministic: only entries with a non-empty target, sorted
    /// by source term.
    public static let maxCorpusItems = 1000

    public static func glossaryList(from entries: [GlossaryEntry]) -> [(source: String, target: String)] {
        let fixed = entries
            .filter { !$0.targetTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (source: $0.sourceTerm, target: $0.targetTranslation) }
            .sorted { $0.source < $1.source }
        return Array(fixed.prefix(maxCorpusItems))
    }

    /// Post-check for the fallback path: returns the glossary terms
    /// whose fixed translation does NOT appear in the translated
    /// text. The caller re-translates or warns on the misses.
    public static func missingTerms(in translation: String, glossary: [(source: String, target: String)]) -> [(source: String, target: String)] {
        glossary.filter { !containsTerm(translation, $0.target) }
    }

    /// N3: keep only the terms whose source actually appears in this
    /// sentence, using the same matching rule as
    /// `GlossaryPrompt.entries(for:from:)`. Without this, the caller
    /// passes the whole table and almost every sentence "misses"
    /// most of it, triggering a wasted re-translation each time.
    public static func termsAppearing(in sentence: String, from glossary: [(source: String, target: String)]) -> [(source: String, target: String)] {
        glossary.filter { entry in
            guard !entry.source.isEmpty else { return false }
            if entry.source.contains(where: { $0.isLetter && !$0.isASCII }) {
                return sentence.contains(entry.source)
            }
            return sentence.lowercased().contains(entry.source.lowercased())
        }
    }

    /// N3: word-boundary, case-insensitive match for Latin terms, so
    /// "bank" no longer matches "banking" and "Bank" matches "bank".
    /// Non-ASCII (CJK) terms have no word boundaries: plain contains.
    private static func containsTerm(_ text: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return true }
        if term.contains(where: { $0.isLetter && !$0.isASCII }) {
            return text.contains(term)
        }
        let lowerText = text.lowercased()
        let lowerTerm = term.lowercased()
        var from = lowerText.startIndex
        while let range = lowerText.range(of: lowerTerm, range: from..<lowerText.endIndex) {
            let beforeOK = range.lowerBound == lowerText.startIndex
                || !isWordChar(lowerText[lowerText.index(before: range.lowerBound)])
            let afterOK = range.upperBound == lowerText.endIndex
                || !isWordChar(lowerText[range.upperBound])
            if beforeOK && afterOK { return true }
            from = range.upperBound
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
