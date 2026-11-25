import Combine
import Foundation

/// Simultaneous-interpretation session engine: owns the live
/// Seed-LiveInterpret sessions (one per direction), the sequential
/// fallback chain (ASR → DeepSeek → TTS), the earphone router, and
/// the quota / latency bookkeeping. The view observes the @Published
/// state; the engine never touches SwiftData itself — `stop()`
/// returns a plain record the view persists.
///
/// Modes:
/// - Live: mic audio goes to the AST v2 session(s); subtitles and
///   TTS audio stream back. Left ear hears the original, right ear
///   the translation.
/// - Fallback: entered automatically when the live path fails
///   (network loss, service error, or the missing grant) and kept
///   until the user retries live. Sentences are translated as they
///   settle (one sentence of lag) so the session never freezes.
///
/// Bidirectional: two parallel sessions share the mic audio. The
/// output gate keeps only segments whose source language matches
/// the session's expected source language (`TextLanguage.detect`),
/// because the wrong-direction session receives audio in a language
/// it does not expect and its behaviour there is unverified — the
/// gate is heuristic until real sessions confirm it. The user can
/// lock to one direction at any time.
///
/// Device-only: the live path, recorder, and router cannot run in
/// CI. The assembler, quota, latency, and glossary rules are
/// unit-tested; the engine's wiring is verified by the cloud build.
@MainActor
public final class InterpretationEngine: ObservableObject {
    public enum Direction: String, CaseIterable, Sendable {
        case zhToEn
        case enToZh
        case both

        public var title: String {
            switch self {
            case .zhToEn: "中文 → 英文"
            case .enToZh: "英文 → 中文"
            case .both: "双向"
            }
        }

        var forwardSource: ASTLanguage {
            switch self {
            case .zhToEn, .both: .zh
            case .enToZh: .en
            }
        }

        var forwardTarget: ASTLanguage {
            switch self {
            case .zhToEn, .both: .en
            case .enToZh: .zh
            }
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case connecting
        case live
        case fallback
        case paused
        case stopped
        case error
    }

    public enum Mode: Sendable, Equatable {
        case live
        case fallback
    }

    /// Fallback translation: text, source language, target language,
    /// and an extra instruction for the model (empty on the first
    /// pass; the missed glossary terms on a retry).
    /// @MainActor because the production implementation calls the
    /// @MainActor translation pipeline.
    public typealias Translator = @MainActor (String, ASTLanguage, ASTLanguage, String) async throws -> String
    /// Fallback speech: translated text -> MP3 data.
    public typealias Speaker = @MainActor (String) async throws -> Data

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var mode: Mode = .live
    @Published public private(set) var direction: Direction = .zhToEn
    @Published public private(set) var segments: [InterpretationSegment] = []
    @Published public private(set) var liveDraftSource = ""
    @Published public private(set) var liveDraftTranslation = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var grantPending = false
    @Published public private(set) var fallbackReason: String?
    @Published public private(set) var isPaused = false
    @Published public private(set) var latency: LatencyBudget.Measurement?
    @Published public private(set) var quota: InterpretationQuotaStore.Snapshot
    @Published public private(set) var lockedDirection: Direction?

    private let quotaStore: InterpretationQuotaStore
    private let router = EarphoneRouter()
    private let recorder = VoiceRecorder()

    private var config: VolcanoVoiceConfig?
    private var glossary: [(source: String, target: String)] = []
    private var translator: Translator?
    private var speaker: Speaker?

    private var forwardClient: LiveInterpretClient?
    private var reverseClient: LiveInterpretClient?
    private var forwardAssembler: InterpretationSegmentAssembler?
    private var reverseAssembler: InterpretationSegmentAssembler?
    private var eventTasks: [Task<Void, Never>] = []
    private var audioFeedTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private var sessionStartTime: Date?
    private var sessionEndTime: Date?
    private var firstAudioSentAt: Date?
    private var latencyMeasurement = LatencyBudget.Measurement()
    private var asrClient: VolcanoASRClient?
    private var fallbackTranslated: [String] = []
    private var fallbackTask: Task<Void, Never>?
    private var autoRetried = false

    public init(quotaStore: InterpretationQuotaStore = InterpretationQuotaStore()) {
        self.quotaStore = quotaStore
        self.quota = quotaStore.snapshot()
    }

    // MARK: - Lifecycle

    public func start(
        direction: Direction,
        config: VolcanoVoiceConfig,
        glossary: [(source: String, target: String)],
        translator: @escaping Translator,
        speaker: @escaping Speaker
    ) async {
        guard phase == .idle || phase == .stopped || phase == .error else { return }
        self.direction = direction
        self.config = config
        self.glossary = glossary
        self.translator = translator
        self.speaker = speaker
        self.segments = []
        self.liveDraftSource = ""
        self.liveDraftTranslation = ""
        self.errorMessage = nil
        self.grantPending = false
        self.fallbackReason = nil
        self.isPaused = false
        self.lockedDirection = nil
        self.latencyMeasurement = LatencyBudget.Measurement()
        self.latency = nil
        self.autoRetried = false
        self.sessionStartTime = .now
        self.sessionEndTime = nil
        self.firstAudioSentAt = nil
        self.fallbackTranslated = []
        phase = .connecting
        mode = .live
        await startLiveSessions()
    }

    public func pause() {
        guard phase == .live || phase == .fallback else { return }
        isPaused = true
        phase = .paused
        recorder.stop()
        router.stop()
    }

    public func resume() async {
        guard phase == .paused else { return }
        isPaused = false
        phase = mode == .live ? .live : .fallback
        try? router.start()
        startAudioFeed()
    }

    /// Stops everything and returns the session record for the view
    /// to persist. Safe to call twice.
    public func stop() async -> InterpretationSessionRecord {
        // Mark stopped first: event-stream teardown below must not
        // trigger a fallback switch on the way out.
        phase = .stopped
        sessionEndTime = .now
        retryTask?.cancel()
        retryTask = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        for task in eventTasks { task.cancel() }
        eventTasks = []
        recorder.stop()
        router.stop()
        if mode == .fallback {
            await finishFallbackRemainder()
        }
        if let forwardClient { await forwardClient.finish() }
        if let reverseClient { await reverseClient.finish() }
        forwardClient = nil
        reverseClient = nil
        await asrClient?.cancel()
        asrClient = nil
        if let start = sessionStartTime, let end = sessionEndTime {
            quotaStore.recordASR(minutes: end.timeIntervalSince(start) / 60.0)
        }
        quota = quotaStore.snapshot()
        return InterpretationSessionRecord(
            startedAt: sessionStartTime ?? .now,
            endedAt: sessionEndTime ?? .now,
            direction: direction,
            mode: mode,
            segments: segments,
            latency: latency
        )
    }

    /// Manual retry: tear the fallback down and try the live path
    /// again. No-op when already live.
    public func retryLive() async {
        guard mode == .fallback && (phase == .fallback || phase == .paused) else { return }
        await startLiveSessions()
    }

    /// Locks bidirectional sessions to one direction (stops the other
    /// session). Pass nil to unlock and restart both.
    public func lockDirection(_ direction: Direction?) async {
        guard self.direction == .both else { return }
        lockedDirection = direction
        if mode == .live {
            await startLiveSessions()
        }
    }

    // MARK: - Live path

    private func activeDirections() -> [Direction] {
        switch direction {
        case .zhToEn: return [.zhToEn]
        case .enToZh: return [.enToZh]
        case .both:
            if let locked = lockedDirection { return [locked] }
            return [.zhToEn, .enToZh]
        }
    }

    private func startLiveSessions() async {
        guard let config else { return }
        phase = .connecting
        // Tear down any previous live sessions (retry / lock change).
        for task in eventTasks { task.cancel() }
        eventTasks = []
        if let forwardClient { await forwardClient.cancel() }
        if let reverseClient { await reverseClient.cancel() }
        forwardClient = nil
        reverseClient = nil
        forwardAssembler = nil
        reverseAssembler = nil

        let directions = activeDirections()
        var startedAny = false
        var startedCount = 0
        var lastError: String?
        for (index, dir) in directions.enumerated() {
            let isForward = index == 0
            let sessionConfig = ASTSessionConfig(
                mode: .s2s,
                sourceLanguage: dir.forwardSource,
                targetLanguage: dir.forwardTarget,
                glossary: glossary
            )
            let client = LiveInterpretClient(config: config, sessionConfig: sessionConfig)
            do {
                let stream = try await client.start()
                if isForward {
                    forwardClient = client
                    forwardAssembler = InterpretationSegmentAssembler(direction: dir == .enToZh ? .enToZh : .zhToEn)
                } else {
                    reverseClient = client
                    reverseAssembler = InterpretationSegmentAssembler(direction: .enToZh)
                }
                eventTasks.append(Task { [weak self] in
                    guard let self else { return }
                    for await event in stream {
                        await self.handleLiveEvent(event, isForward: isForward)
                    }
                    await self.handleLiveStreamEnded()
                })
                startedAny = true
                startedCount += 1
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        if startedAny {
            mode = .live
            phase = isPaused ? .paused : .live
            grantPending = false
            fallbackReason = nil
            if startedCount < directions.count {
                let detail = lastError ?? "未知原因"
                errorMessage = "其中一个方向连接失败（\(detail)，仅单向运行。"
            }
            await startRouterAndFeed()
            fallbackTask?.cancel()
            fallbackTask = nil
            await asrClient?.cancel()
            asrClient = nil
        } else {
            // No live session at all: fall back to the sequential line.
            grantPending = true
            await switchToFallback(reason: lastError ?? "同传连接失败")
        }
    }

    private func startRouterAndFeed() async {
        do {
            try router.start()
        } catch {
            // Playback failure must not kill the session; subtitles
            // still flow and the fallback keeps working.
            errorMessage = "耳机路由启动失败：\(error.localizedDescription)"
        }
        startAudioFeed()
    }

    private func startAudioFeed() {
        audioFeedTask?.cancel()
        audioFeedTask = nil
        // Stopping the recorder finishes the previous stream, so a
        // superseded feed loop exits instead of lingering suspended.
        recorder.stop()
        audioFeedTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.recorder.start()
                for await chunk in stream {
                    await self.handleAudioChunk(chunk)
                }
            } catch {
                await self.handleAudioError(error)
            }
        }
    }

    private func handleAudioChunk(_ chunk: Data) async {
        if isPaused { return }
        if firstAudioSentAt == nil { firstAudioSentAt = .now }
        if mode == .live {
            try? await forwardClient?.sendAudio(chunk)
            try? await reverseClient?.sendAudio(chunk)
        } else if let asrClient {
            try? await asrClient.sendAudio(chunk)
        }
        router.playOriginal(pcm: chunk)
    }

    private func handleAudioError(_ error: Error) async {
        // Mic errors end the session the same way a network loss
        // does: fall back if live, otherwise report and stop.
        if mode == .live {
            await switchToFallback(reason: "麦克风中断：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        } else {
            errorMessage = "麦克风中断：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            phase = .error
        }
    }

    private func handleLiveEvent(_ event: LiveInterpretClient.Event, isForward: Bool) async {
        switch event {
        case .ttsAudio(let pcm):
            if latencyMeasurement.firstTTSAudioMs == nil, let sent = firstAudioSentAt {
                latencyMeasurement.firstTTSAudioMs = Date().timeIntervalSince(sent) * 1000
                latency = latencyMeasurement
            }
            router.playTranslation(pcm: pcm)
        case .translationPartial:
            if latencyMeasurement.firstTranslationTextMs == nil, let sent = firstAudioSentAt {
                latencyMeasurement.firstTranslationTextMs = Date().timeIntervalSince(sent) * 1000
                if latencyMeasurement.sessionStartToFirstTranslationMs == nil, let start = sessionStartTime {
                    latencyMeasurement.sessionStartToFirstTranslationMs = Date().timeIntervalSince(start) * 1000
                }
                latency = latencyMeasurement
            }
        case .usage(let billing):
            var inputAudio = 0.0, outputText = 0.0, outputAudio = 0.0
            for item in billing.items {
                switch item.unit {
                case "input_audio_tokens": inputAudio += Double(item.quantity)
                case "output_text_tokens": outputText += Double(item.quantity)
                case "output_audio_tokens": outputAudio += Double(item.quantity)
                default: break
                }
            }
            quotaStore.recordLiveSession(
                durationMsec: billing.durationMsec,
                inputAudioTokens: inputAudio,
                outputTextTokens: outputText,
                outputAudioTokens: outputAudio
            )
            quota = quotaStore.snapshot()
        case .failed(let detail):
            await switchToFallback(reason: detail)
        default:
            break
        }

        // Segment assembly, per direction, with the output gate.
        if isForward {
            forwardAssembler?.apply(event)
        } else {
            reverseAssembler?.apply(event)
        }
        publishSegments()
    }

    private func handleLiveStreamEnded() async {
        // A live stream ending without an explicit failure is still a
        // broken session: fall back rather than going silent.
        guard phase == .live || phase == .connecting else { return }
        await switchToFallback(reason: "同传连接中断")
    }

    private func publishSegments() {
        // Keep fallback segments: the live assemblers only hold live
        // ones, and publish must not wipe the fallback history after
        // a retry back to live.
        var merged = segments.filter { $0.mode == .fallback }
        if let forward = forwardAssembler {
            merged.append(contentsOf: forward.segments.filter { Self.passesGate($0, expectedSource: forwardExpectedLanguage()) })
        }
        if let reverse = reverseAssembler {
            merged.append(contentsOf: reverse.segments.filter { Self.passesGate($0, expectedSource: .english) })
        }
        merged.sort { $0.createdAt < $1.createdAt }
        segments = merged
        // Live drafts: primary direction first, the other as backup.
        if let forward = forwardAssembler, !forward.liveDraft.source.isEmpty || !forward.liveDraft.translation.isEmpty {
            liveDraftSource = forward.liveDraft.source
            liveDraftTranslation = forward.liveDraft.translation
        } else if let reverse = reverseAssembler {
            liveDraftSource = reverse.liveDraft.source
            liveDraftTranslation = reverse.liveDraft.translation
        }
    }

    private func forwardExpectedLanguage() -> TextLanguage {
        direction == .enToZh ? .english : .chinese
    }

    /// Bidirectional output gate: a segment only counts when its
    /// source text is in the language the session expects. The
    /// wrong-direction session gets the same mic audio in a language
    /// it does not expect; until real sessions confirm what it does
    /// with that audio, its output stays hidden.
    nonisolated public static func passesGate(_ segment: InterpretationSegment, expectedSource: TextLanguage) -> Bool {
        guard !segment.sourceText.isEmpty else { return true }
        return TextLanguage.detect(segment.sourceText) == expectedSource
    }

    // MARK: - Fallback path

    private func switchToFallback(reason: String) async {
        guard phase != .stopped && phase != .idle else { return }
        guard mode != .fallback || phase != .fallback else { return }
        mode = .fallback
        phase = isPaused ? .paused : .fallback
        fallbackReason = reason
        errorMessage = nil
        for task in eventTasks { task.cancel() }
        eventTasks = []
        if let forwardClient { await forwardClient.cancel() }
        if let reverseClient { await reverseClient.cancel() }
        forwardClient = nil
        reverseClient = nil
        // One automatic retry after 30s; after that the user retries
        // manually from the banner.
        if !autoRetried {
            autoRetried = true
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.mode == .fallback, (self.phase == .fallback || self.phase == .paused) else { return }
                await self.startLiveSessions()
            }
        }
        await startFallbackChain()
    }

    private func startFallbackChain() async {
        guard let config else { return }
        fallbackTask?.cancel()
        await asrClient?.cancel()
        let client = VolcanoASRClient(config: config)
        asrClient = client
        await startRouterAndFeed()
        fallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.start()
                for await (text, _) in stream {
                    await self.handleFallbackTranscript(text)
                }
            } catch {
                // The ASR stream ending mid-session is not fatal: the
                // remainder is translated on stop().
            }
        }
    }

    /// Translates settled sentences as they appear in the cumulative
    /// ASR transcript. A sentence is translated once the next one has
    /// started (so the model is no longer revising it); the last
    /// sentence is translated on stop().
    private func handleFallbackTranscript(_ text: String) async {
        let sentences = TextSegmenter.splitSentences(text)
        guard sentences.count >= 2 else { return }
        for sentence in sentences.dropLast() {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !fallbackTranslated.contains(trimmed) else { continue }
            fallbackTranslated.append(trimmed)
            await translateFallbackSentence(trimmed)
        }
    }

    private func translateFallbackSentence(_ sentence: String) async {
        guard let translator, let speaker else { return }
        let startedAt = Date()
        let sourceLanguage = TextLanguage.detect(sentence) == .chinese ? ASTLanguage.zh : ASTLanguage.en
        let targetLanguage = sourceLanguage == .zh ? ASTLanguage.en : ASTLanguage.zh
        do {
            var translation = try await translator(sentence, sourceLanguage, targetLanguage, "")
            // Glossary post-check: the live path only hints the
            // model, but here the terms can be enforced. Re-ask once
            // with the missed terms spelled out as an instruction
            // (not as text to translate).
            let missed = GlossaryAST.missingTerms(in: translation, glossary: glossary)
            if !missed.isEmpty {
                let note = "必须按术语表翻译：" + missed.map { "\($0.source)=\($0.target)" }.joined(separator: "，")
                let retry = try? await translator(sentence, sourceLanguage, targetLanguage, note)
                if let retry, !retry.isEmpty { translation = retry }
            }
            let latencyMs = Date().timeIntervalSince(startedAt) * 1000
            segments.append(InterpretationSegment(
                direction: sourceLanguage == .zh ? .zhToEn : .enToZh,
                mode: .fallback,
                sourceText: sentence,
                translationText: translation,
                latencyMs: latencyMs
            ))
            quotaStore.recordTTS(chars: translation.count)
            quota = quotaStore.snapshot()
            let audio = try await speaker(translation)
            router.playTranslationMP3(audio)
        } catch {
            errorMessage = "顺序语音线翻译失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func finishFallbackRemainder() async {
        // Translate whatever the ASR stream left untranslated.
        guard let client = asrClient else { return }
        let remainder = (try? await client.finish()) ?? ""
        let sentences = TextSegmenter.splitSentences(remainder)
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !fallbackTranslated.contains(trimmed) else { continue }
            fallbackTranslated.append(trimmed)
            await translateFallbackSentence(trimmed)
        }
    }
}

/// Plain record of a finished session, for the view to persist into
/// SwiftData. The engine stays persistence-free.
public struct InterpretationSessionRecord: Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var direction: InterpretationEngine.Direction
    public var mode: InterpretationEngine.Mode
    public var segments: [InterpretationSegment]
    public var latency: LatencyBudget.Measurement?

    public var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }
}
