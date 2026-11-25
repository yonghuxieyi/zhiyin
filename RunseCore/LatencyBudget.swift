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
    public var playbackMs: Double = 150

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
        glossary.filter { !translation.contains($0.target) }
    }
}
