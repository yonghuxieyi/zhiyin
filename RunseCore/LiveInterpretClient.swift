import Foundation

/// Seed-LiveInterpret 2.0 (豆包同声传译 2.0) WebSocket client: one
/// instance per direction (zh→en or en→zh). Audio in is 16kHz 16-bit
/// mono PCM in ~80ms packets; audio out is 24kHz PCM (no Opus
/// decoding needed on device). Subtitles arrive incrementally
/// (Response events carry the current text, End events carry the
/// settled text — a corrected re-speak replaces, never appends).
///
/// Verified 2026-11-25 from this VM: the handshake reaches the
/// gateway with the voice-console AppID + Access Token, but the
/// Zhiyin application has no grant for `volc.service_type.10053`
/// (HTTP 403 "requested resource not granted"). The client is
/// complete and fixture-tested; end-to-end audio only flows after
/// the service is enabled for the Zhiyin app in the voice console.
/// Until then the engine shows a "待开通" banner with the steps.
public actor LiveInterpretClient {
    public enum ClientError: Error, LocalizedError {
        case notConfigured
        case connectionFailed(String)
        case sessionFailed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "语音未配置：先在“语音”页填 AppID 和 Access Token。"
            case .connectionFailed(let detail):
                return "同传连接失败：\(detail)"
            case .sessionFailed(let detail):
                return "同传会话失败：\(detail)"
            case .timedOut:
                return "同传连接超时。"
            }
        }
    }

    public enum Event: Sendable {
        case sessionStarted
        case sourceStarted(speakerChanged: Bool)
        case sourcePartial(text: String)
        case sourceFinal(text: String, startMs: Int64, endMs: Int64, speakerChanged: Bool)
        case translationStarted(speakerChanged: Bool)
        case translationPartial(text: String)
        case translationFinal(text: String, startMs: Int64, endMs: Int64, speakerChanged: Bool)
        case ttsAudio(Data)
        case ttsSentenceStarted
        case ttsSentenceEnded
        case muted(durationMs: Int64)
        case usage(ASTBilling)
        case sessionFinished
        case failed(String)
    }

    public static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v4/ast/v2/translate")!
    public static let resourceID = "volc.service_type.10053"

    private let config: VolcanoVoiceConfig
    private let sessionConfig: ASTSessionConfig
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var sessionStarted = false
    private var sessionFailure: String?
    private var sessionFinished = false
    /// D1: set by cancel() so a start() that is still waiting for
    /// SessionStarted can end promptly instead of returning a stream
    /// for a socket that was just cancelled.
    private var stopped = false

    public init(config: VolcanoVoiceConfig, sessionConfig: ASTSessionConfig, session: URLSession = .shared) {
        self.config = config
        self.sessionConfig = sessionConfig
        self.session = session
    }

    /// M10: whether the WebSocket is up and the session actually
    /// started (not finished). Used on resume to decide whether the
    /// paused session can continue or must be rebuilt.
    public var isConnected: Bool {
        task?.state == .running && sessionStarted && !sessionFinished
    }

    /// Connects and starts the session. Returns the event stream only
    /// after SessionStarted arrives (audio must not be sent before it).
    /// Throws on handshake failure, session failure, or a 10s timeout.
    public func start() async throws -> AsyncStream<Event> {
        guard config.isComplete else { throw ClientError.notConfigured }
        // D1: a reused client must not carry the previous session's
        // state — a stale sessionStarted=true would make this call
        // return before the new session actually started.
        stopped = false
        sessionStarted = false
        sessionFailure = nil
        sessionFinished = false
        var request = URLRequest(url: Self.endpoint)
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(Self.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        eventContinuation = continuation
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        do {
            try await task.send(.data(ASTRequest.startSession(config: sessionConfig)))
        } catch {
            await cancel()
            throw ClientError.connectionFailed(error.localizedDescription)
        }
        // S3: the 10 s wait must not leak the socket/receiveTask when
        // the caller cancels mid-wait — Task.sleep throws
        // CancellationError, which used to escape start() without
        // anyone closing the socket.
        do {
            let deadline = Date().addingTimeInterval(10)
            while !sessionStarted {
                // D1: stop() during connection establishment must end
                // this wait instead of letting start() return a stream
                // for a socket that was just cancelled (the session
                // would "revive" after the user stopped it).
                if stopped {
                    await cancel()
                    throw ClientError.connectionFailed("同传已停止")
                }
                if let failure = sessionFailure {
                    await cancel()
                    throw ClientError.sessionFailed(failure)
                }
                if Date() > deadline {
                    await cancel()
                    throw ClientError.timedOut
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch is CancellationError {
            await cancel()
            throw error
        }
        // D1: the loop above exits when the session starts — but a
        // stop() that landed in the same instant must still win over
        // returning a stream for a cancelled socket.
        if stopped {
            await cancel()
            throw ClientError.connectionFailed("同传已停止")
        }
        return stream
    }

    /// Sends one audio packet (16kHz 16-bit mono PCM, ~80ms = 2560
    /// bytes). Must only be called after `start()` returns.
    public func sendAudio(_ pcm: Data) async throws {
        guard let task else { throw ClientError.connectionFailed("同传未连接") }
        try await task.send(.data(ASTRequest.taskRequest(sessionID: sessionConfig.sessionID, audio: pcm)))
    }

    /// Updates the glossary / hot words mid-session (event 201).
    public func updateGlossary(_ glossary: [(source: String, target: String)], hotWords: [String] = []) async throws {
        guard let task else { throw ClientError.connectionFailed("同传未连接") }
        let bytes = ASTRequest.updateConfig(sessionID: sessionConfig.sessionID, mode: sessionConfig.mode, glossary: glossary, hotWords: hotWords)
        try await task.send(.data(bytes))
    }

    /// Ends the session gracefully and waits up to 3s for
    /// SessionFinished, then closes the socket.
    public func finish() async {
        guard let task else { return }
        try? await task.send(.data(ASTRequest.finishSession(sessionID: sessionConfig.sessionID)))
        let deadline = Date().addingTimeInterval(3)
        while !sessionFinished && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await cancel()
    }

    public func cancel() async {
        stopped = true
        sessionStarted = false
        sessionFailure = nil
        sessionFinished = false
        eventContinuation?.finish()
        eventContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() async {
        guard let task else { return }
        // D1: hold this generation's continuation. The trailing
        // finish below must not finish a NEWER stream's continuation
        // if cancel() + a fresh start() already replaced it.
        let continuation = eventContinuation
        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    handleResponseData(data, continuation: continuation)
                case .string:
                    // The AST protocol never sends text frames.
                    continue
                @unknown default:
                    continue
                }
            } catch {
                break
            }
        }
        continuation?.finish()
    }

    private func handleResponseData(_ data: Data, continuation: AsyncStream<Event>.Continuation?) {
        // D1: a message that arrived just as cancel() ran must not
        // set flags or yield events into a dead (or newer) session.
        guard !stopped else { return }
        guard let response = ASTResponse.decode(data) else { return }
        if response.isError, let code = response.statusCode {
            let detail = response.message.map { "\($0) (\(code))" } ?? "错误码 \(code)"
            sessionFailure = detail
            continuation?.yield(.failed(detail))
            return
        }
        switch response.event {
        case .sessionStarted:
            sessionStarted = true
            continuation?.yield(.sessionStarted)
        case .sourceSubtitleStart:
            continuation?.yield(.sourceStarted(speakerChanged: response.speakerChanged))
        case .sourceSubtitleResponse:
            if let text = response.text { continuation?.yield(.sourcePartial(text: text)) }
        case .sourceSubtitleEnd:
            continuation?.yield(.sourceFinal(
                text: response.text ?? "",
                startMs: response.startTime ?? 0,
                endMs: response.endTime ?? 0,
                speakerChanged: response.speakerChanged
            ))
        case .translationSubtitleStart:
            continuation?.yield(.translationStarted(speakerChanged: response.speakerChanged))
        case .translationSubtitleResponse:
            if let text = response.text { continuation?.yield(.translationPartial(text: text)) }
        case .translationSubtitleEnd:
            continuation?.yield(.translationFinal(
                text: response.text ?? "",
                startMs: response.startTime ?? 0,
                endMs: response.endTime ?? 0,
                speakerChanged: response.speakerChanged
            ))
        case .ttsResponse:
            if let audio = response.data { continuation?.yield(.ttsAudio(audio)) }
        case .ttsSentenceStart:
            continuation?.yield(.ttsSentenceStarted)
        case .ttsSentenceEnd:
            continuation?.yield(.ttsSentenceEnded)
        case .audioMuted:
            continuation?.yield(.muted(durationMs: response.mutedDurationMs ?? 0))
        case .usageResponse:
            if let billing = response.billing { continuation?.yield(.usage(billing)) }
        case .sessionFinished:
            sessionFinished = true
            continuation?.yield(.sessionFinished)
        case .sessionFailed:
            let detail = response.message ?? "会话失败"
            sessionFailure = detail
            continuation?.yield(.failed(detail))
        default:
            // Start/End markers carry no text of their own.
            break
        }
    }
}
