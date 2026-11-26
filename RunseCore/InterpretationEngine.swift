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
    /// Streaming fallback speech: translated text -> audio played as it
    /// streams (the closure owns playback). When set, the sequential
    /// line uses it first and falls back to `Speaker` (async MP3) when
    /// streaming fails for a sentence.
    public typealias StreamingSpeaker = @MainActor (String) async throws -> Void

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
    private var streamingSpeaker: StreamingSpeaker?

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
    /// M7: generation counter for live sessions. Every
    /// `startLiveSessions` bumps it; event tasks and stream-end
    /// callbacks carry the generation they were started with, and
    /// anything from an older generation is ignored — otherwise an
    /// old session's teardown could kill a freshly started one.
    private var sessionGeneration = 0
    /// D1: clients whose start() is still being awaited in
    /// startLiveSessions. stop() cannot see them through
    /// forwardClient/reverseClient yet, so they are tracked here to
    /// be cancelled immediately instead of reviving the session.
    private var connectingClients: [LiveInterpretClient] = []
    /// M10: when the session was paused, to decide on resume whether
    /// the socket is too stale to continue.
    private var pausedAt: Date?
    /// M10: consecutive live `sendAudio` failures; hitting the
    /// threshold falls back instead of going silently dead.
    private var consecutiveSendFailures = 0

    public init(quotaStore: InterpretationQuotaStore = InterpretationQuotaStore()) {
        self.quotaStore = quotaStore
        self.quota = quotaStore.snapshot()
    }

    /// N6 backstop: if the engine is dropped without `stop()` (view
    /// dismissed mid-session), at least cancel the background work
    /// and close the live sockets instead of leaking them.
    /// NOTE: `recorder`/`router` are deliberately NOT touched here:
    /// Swift 6 forbids a nonisolated deinit from accessing the
    /// @MainActor engine's non-Sendable stored properties (that was
    /// the CI failure). Both stop themselves in their own deinit,
    /// which runs right after this body when the engine releases them.
    deinit {
        retryTask?.cancel()
        audioFeedTask?.cancel()
        fallbackTask?.cancel()
        for task in eventTasks { task.cancel() }
        let forward = forwardClient
        let reverse = reverseClient
        let connecting = connectingClients
        Task { [forward, reverse, connecting] in
            await forward?.cancel()
            await reverse?.cancel()
            for client in connecting { await client.cancel() }
        }
    }

    // MARK: - Lifecycle

    public func start(
        direction: Direction,
        config: VolcanoVoiceConfig,
        glossary: [(source: String, target: String)],
        translator: @escaping Translator,
        speaker: @escaping Speaker,
        streamingSpeaker: StreamingSpeaker? = nil
    ) async {
        guard phase == .idle || phase == .stopped || phase == .error else { return }
        self.direction = direction
        self.config = config
        self.glossary = glossary
        self.translator = translator
        self.speaker = speaker
        self.streamingSpeaker = streamingSpeaker
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
        pausedAt = .now
        recorder.stop()
        router.stop()
    }

    public func resume() async {
        guard phase == .paused else { return }
        isPaused = false
        // M10: a paused live session may be a dead socket — the
        // WebSocket can time out while paused and `sendAudio` would
        // then fail silently. If paused over 60s, or neither live
        // client is still connected, rebuild the session instead of
        // resuming a dead one.
        let pausedFor = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        pausedAt = nil
        if mode == .live {
            // LiveInterpretClient is an actor: isConnected needs await.
            // Each await must be its own statement: `||` / `??` take
            // @autoclosure operands, which cannot contain `await`.
            let forwardConnected = await forwardClient?.isConnected ?? false
            let reverseConnected = await reverseClient?.isConnected ?? false
            let anyConnected = forwardConnected || reverseConnected
            if pausedFor > 60 || !anyConnected {
                await startLiveSessions()
                return
            }
        }
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
        // D1: cancel clients still connecting — they only exist as
        // locals in startLiveSessions, so without this the awaited
        // start() would return after stop() and go live again.
        for client in connectingClients { await client.cancel() }
        connectingClients = []
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
        streamingSpeaker = nil
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
        // M7: bump the generation first. The old event tasks are
        // cancelled below, but their stream-end callbacks can still
        // fire afterwards — they carry the old generation and are
        // ignored in handleLiveStreamEnded / handleLiveEvent.
        sessionGeneration += 1
        let generation = sessionGeneration
        consecutiveSendFailures = 0
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
            connectingClients.append(client)
            do {
                let stream = try await client.start()
                connectingClients.removeAll { $0 === client }
                if isForward {
                    forwardClient = client
                    forwardAssembler = InterpretationSegmentAssembler(direction: dir == .enToZh ? .enToZh : .zhToEn)
                } else {
                    reverseClient = client
                    reverseAssembler = InterpretationSegmentAssembler(direction: .enToZh)
                }
                eventTasks.append(Task { [weak self, generation] in
                    guard let self else { return }
                    for await event in stream {
                        await self.handleLiveEvent(event, isForward: isForward, generation: generation)
                    }
                    await self.handleLiveStreamEnded(generation: generation)
                })
                startedAny = true
                startedCount += 1
            } catch {
                connectingClients.removeAll { $0 === client }
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // D1: stop() may have run while a client was still
        // connecting (its start() was awaited above, so stop() could
        // not see or cancel it through forwardClient). Never revive
        // a stopped session: drop the clients and return without
        // going live or falling back.
        if phase == .stopped || generation != sessionGeneration {
            for task in eventTasks { task.cancel() }
            eventTasks = []
            if let forwardClient { await forwardClient.cancel() }
            if let reverseClient { await reverseClient.cancel() }
            forwardClient = nil
            reverseClient = nil
            return
        }

        if startedAny {
            mode = .live
            phase = isPaused ? .paused : .live
            grantPending = false
            fallbackReason = nil
            // Back on live: allow one automatic retry again if this
            // session drops later. (Only reset on success — resetting
            // on failure would loop the 30s retry forever.)
            autoRetried = false
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
            await sendLiveAudio(chunk)
        } else if let asrClient {
            try? await asrClient.sendAudio(chunk)
        }
        router.playOriginal(pcm: chunk)
    }

    /// M10: sends one audio chunk to the live session(s), counting
    /// consecutive failures. The old code swallowed send errors with
    /// `try?`, so a dead socket went silently quiet instead of
    /// falling back. Five consecutive failures (~half a second of
    /// audio) trigger the fallback.
    private func sendLiveAudio(_ chunk: Data) async {
        var attempted = false
        var failed = false
        if let forwardClient {
            attempted = true
            do { try await forwardClient.sendAudio(chunk) } catch { failed = true }
        }
        if let reverseClient {
            attempted = true
            do { try await reverseClient.sendAudio(chunk) } catch { failed = true }
        }
        guard attempted else { return }
        if failed {
            consecutiveSendFailures += 1
            if consecutiveSendFailures >= 5 {
                consecutiveSendFailures = 0
                await switchToFallback(reason: "同传发送失败（连接已断）")
            }
        } else {
            consecutiveSendFailures = 0
        }
    }

    private func handleAudioError(_ error: Error) async {
        // N7: a denied mic permission is a setup problem, not a
        // mid-session interruption — surface it as-is (no fallback:
        // the fallback line needs the mic too) so the view can offer
        // the Settings button for it.
        if let recorderError = error as? VoiceRecorder.RecorderError,
           case .micPermissionDenied = recorderError {
            errorMessage = recorderError.localizedDescription
            phase = .error
            return
        }
        // Mic errors end the session the same way a network loss
        // does: fall back if live, otherwise report and stop.
        if mode == .live {
            await switchToFallback(reason: "麦克风中断：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        } else {
            errorMessage = "麦克风中断：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            phase = .error
        }
    }

    private func handleLiveEvent(_ event: LiveInterpretClient.Event, isForward: Bool, generation: Int) async {
        // M7: ignore events from a superseded session generation, and
        // stop work if this task was cancelled while tearing down.
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        switch event {
        case .ttsAudio(let pcm):
            if latencyMeasurement.firstTTSAudioMs == nil, let sent = firstAudioSentAt {
                latencyMeasurement.firstTTSAudioMs = Date().timeIntervalSince(sent) * 1000
                latency = latencyMeasurement
            }
            // M9: in bidirectional mode, only play audio from the
            // direction whose source language matches the sentence
            // being spoken — the other session also receives the mic
            // audio and would otherwise play its (wrong-direction)
            // output over it. See shouldPlayLiveAudio.
            if shouldPlayLiveAudio(isForward: isForward) {
                router.playTranslation(pcm: pcm)
            }
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

    private func handleLiveStreamEnded(generation: Int) async {
        // M7: a stream ending from an old generation must not kill
        // the session that replaced it (manual retry, 30s auto-retry,
        // direction lock all rebuild sessions while the old stream
        // is still winding down).
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        // A live stream ending without an explicit failure is still a
        // broken session: fall back rather than going silent.
        guard phase == .live || phase == .connecting else { return }
        await switchToFallback(reason: "同传连接中断")
    }

    /// M9: per-sentence audio gate for bidirectional sessions. The
    /// sentence being spoken is the direction assembler's latest
    /// source text (settled segment, else live draft); if its
    /// detected language does not match what this session expects,
    /// this audio belongs to the other direction and stays silent.
    /// Single-direction sessions always play. When there is no
    /// source text yet to judge by, play — the subtitle gate hides
    /// mismatched text, and blocking audio with no evidence would
    /// mute legitimate first sentences. Heuristic until real
    /// bidirectional sessions confirm the behaviour: 待真机验证.
    private func shouldPlayLiveAudio(isForward: Bool) -> Bool {
        guard direction == .both else { return true }
        let expected: TextLanguage = isForward ? forwardExpectedLanguage() : .english
        let assembler = isForward ? forwardAssembler : reverseAssembler
        let source = assembler?.segments.reversed().first(where: { !$0.sourceText.isEmpty })?.sourceText
            ?? assembler?.liveDraft.source ?? ""
        guard !source.isEmpty else { return true }
        return TextLanguage.detect(source) == expected
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
        // M8: the expected source language is decided by the ACTUAL
        // direction of the forward session, not by `direction`. When
        // direction is .both and the user locked en→zh, the forward
        // session really is en→zh — the old code read `direction`
        // (.both) and expected Chinese, so every English source
        // sentence was filtered and the screen stayed blank.
        let actual = lockedDirection ?? direction
        return actual == .enToZh ? .english : .chinese
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
        guard let translator, speaker != nil || streamingSpeaker != nil else { return }
        let startedAt = Date()
        let sourceLanguage = TextLanguage.detect(sentence) == .chinese ? ASTLanguage.zh : ASTLanguage.en
        let targetLanguage = sourceLanguage == .zh ? ASTLanguage.en : ASTLanguage.zh
        do {
            var translation = try await translator(sentence, sourceLanguage, targetLanguage, "")
            // Glossary post-check: the live path only hints the
            // model, but here the terms can be enforced. Re-ask once
            // with the missed terms spelled out as an instruction
            // (not as text to translate). N3: only check the terms
            // whose source appears in this sentence, or the whole
            // table "misses" almost every sentence and each one
            // pays for a wasted re-translation.
            let relevant = GlossaryAST.termsAppearing(in: sentence, from: glossary)
            let missed = GlossaryAST.missingTerms(in: translation, glossary: relevant)
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
            // Streaming first (audio starts ~0.5 s in); on a streaming
            // failure for this sentence, fall back to the async MP3.
            if let streamingSpeaker {
                do {
                    try await streamingSpeaker(translation)
                } catch {
                    guard let speaker else { throw error }
                    let audio = try await speaker(translation)
                    router.playTranslationMP3(audio)
                }
            } else if let speaker {
                let audio = try await speaker(translation)
                router.playTranslationMP3(audio)
            }
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
