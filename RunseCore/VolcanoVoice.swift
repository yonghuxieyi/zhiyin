import AVFoundation
import Foundation

/// Doubao voice (Volcano engine) streaming ASR 2.0 and TTS 2.0.
///
/// - ASR (streaming recognition): WebSocket binary protocol, per the
///   Volcano "豆包语音" docs. Verified live 2026-11-25 from this VM:
///   the endpoint is `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`
///   (the optimized bidirectional stream), resource
///   `volc.seedasr.sauc.duration`, auth headers `X-Api-App-Key` (AppID),
///   `X-Api-Access-Key` (Access Token), `X-Api-Resource-Id`,
///   `X-Api-Request-Id` (UUID), `X-Api-Sequence: -1`. Do NOT use
///   `/api/v3/sauc/bigmodel` with the 2.0 resource: the gateway rejects
///   it with 400 "resourceId volc.seedasr.sauc.duration is not allowed"
///   (that endpoint only takes the 1.0 resource `volc.bigasr.sauc.duration`).
///   Binary frames: byte 0 `0x11` (protocol v1, 4-byte header), byte 1
///   message type (0x1 full client request, 0x2 audio only, 0x9 full
///   server response, 0xF server error) plus flags, byte 2 serialization
///   (0 raw, 1 JSON) plus compression, byte 3 reserved, then an optional
///   4-byte big-endian sequence number when flags bit 0x1 is set (the
///   server sets it on every result frame), then a 4-byte big-endian
///   payload size and payload. Results are cumulative: each message
///   carries the full text so far, with `utterances` (each has `text`,
///   `start_time`, `end_time`, `definite`, `words`) and a `prefetch` flag
///   on re-recognition passes. An utterance is final when its `definite`
///   is true; the server sends no explicit session-final message, so
///   `finish()` falls back to the last transcript after 8s. Live test:
///   8s of TTS-generated Chinese recognized exactly, first partial at
///   ~0.5s of audio, word-level timestamps included.
/// - TTS (synthesis): V3 ASYNC API, verified working 2026-11-25. Do NOT
///   use the V1 endpoint (`POST /api/v1/tts`, resource `volc.tts`):
///   this app has no grant for it and it returns 401 "load grant:
///   requested grant not found". V3: `POST /api/v3/tts/submit` then
///   `POST /api/v3/tts/query`, resource `seed-tts-2.0`, headers
///   `X-Api-App-Id`, `X-Api-Access-Key`, `X-Api-Resource-Id`,
///   `X-Api-Request-Id`. submit returns `{"code": 20000000, "data":
///   {"task_id": ..., "task_status": 1}}` (task id is under `data`);
///   query returns `data.task_status` 1 running / 2 success / 3 failed
///   and, on success, `data.audio_url`, a signed MP3 link that expires
///   in 1 hour — download it immediately. Verified: "你好，世界" took
///   ~9s, 32904-byte MP3, 1.632s of audio. Do not add an `additions`
///   field (`explicit_language`): the server rejects it.
///   True streaming TTS (audio while text streams) lives in
///   `StreamingTTS.swift` (`VolcanoStreamingTTSClient`): the same
///   endpoint `wss://openspeech.bytedance.com/api/v3/tts/bidirection`,
///   verified live 2026-11-25 with first audio in 557 ms. The async
///   API below stays as the fallback when the stream cannot start.
///
/// The AppID and Access Token live in the keychain (services
/// `Zhiyin.VolcanoAppID` / `Zhiyin.VolcanoAccessToken`, account
/// `default`). They are never written into code or config files. Without
/// them the voice UI reports "not configured" and refuses to start.
public enum VolcanoVoiceError: Error, LocalizedError, Equatable {
    case notConfigured
    case connectionFailed(String)
    case serverError(Int, String)
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Voice is not configured. Add the Volcano AppID and Access Token in Settings."
        case .connectionFailed(let message): "Voice connection failed: \(message)"
        case .serverError(let code, let message): "Voice service error \(code): \(message)"
        case .invalidResponse: "Voice service returned an unreadable response."
        case .timeout: "Voice service timed out."
        }
    }
}

public struct VolcanoVoiceConfig: Sendable, Equatable {
    public var appID: String
    public var accessToken: String

    public init(appID: String, accessToken: String) {
        self.appID = appID
        self.accessToken = accessToken
    }

    public var isComplete: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum VolcanoVoiceStore {
    public static let appIDService = "Zhiyin.VolcanoAppID"
    public static let accessTokenService = "Zhiyin.VolcanoAccessToken"
    public static let account = "default"

    public static func load() async -> VolcanoVoiceConfig? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        let appID = try? await keychain.load(service: appIDService, account: account)
        let token = try? await keychain.load(service: accessTokenService, account: account)
        guard let appID, let token, !appID.isEmpty, !token.isEmpty else { return nil }
        return VolcanoVoiceConfig(appID: appID, accessToken: token)
    }

    public static func save(_ config: VolcanoVoiceConfig) async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(config.appID, service: appIDService, account: account)
        try await keychain.save(config.accessToken, service: accessTokenService, account: account)
    }

    public static func clear() async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.delete(service: appIDService, account: account)
        try await keychain.delete(service: accessTokenService, account: account)
    }
}

// MARK: - Binary frame codec

/// Volcano WebSocket binary frame. Pure functions, covered by unit tests.
public enum VolcanoFrame {
    public static let fullClientRequest: UInt8 = 0x1
    public static let audioOnlyRequest: UInt8 = 0x2
    public static let fullServerResponse: UInt8 = 0x9
    public static let serverError: UInt8 = 0xF

    /// Encodes one frame. `event` is the optional 4-byte event number used
    /// by the TTS v3 protocol; when present the header grows to 8 bytes and
    /// flags must carry the event-present bit (0x4).
    public static func encode(type: UInt8, flags: UInt8, jsonPayload: Data?, rawPayload: Data? = nil, event: Int32? = nil) -> Data {
        var frame = Data()
        let headerSize: UInt8 = event == nil ? 1 : 2
        frame.append((0x1 << 4) | headerSize)
        frame.append((type << 4) | (flags & 0x0F))
        let payload = jsonPayload ?? rawPayload ?? Data()
        let serialization: UInt8 = jsonPayload == nil ? 0x0 : 0x1
        frame.append((serialization << 4) | 0x0)
        frame.append(0x0)
        if let event {
            var eventValue = event.bigEndian
            frame.append(Data(bytes: &eventValue, count: 4))
        }
        var size = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(payload)
        return frame
    }

    public struct DecodedFrame: Sendable, Equatable {
        public var type: UInt8
        public var flags: UInt8
        public var isJSON: Bool
        public var event: Int32?
        /// Server sequence number, present when flags bit 0x1 is set.
        public var sequence: UInt32?
        public var payload: Data
    }

    /// Decodes the first complete frame in `buffer`, returning it and the
    /// number of bytes consumed, or nil when the buffer holds no complete
    /// frame yet. Server result frames carry a 4-byte big-endian sequence
    /// number after the header when flags bit 0x1 is set (verified live
    /// 2026-11-25 on the ASR bigmodel_async endpoint); the sequence is
    /// returned for logging and skipped for the payload.
    public static func decodeFirst(from buffer: Data) -> (frame: DecodedFrame, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let headerSize = Int(buffer[0] & 0x0F) * 4
        let flags = buffer[1] & 0x0F
        let hasSequence = (flags & 0x1) != 0
        let sizeOffset = headerSize + (hasSequence ? 4 : 0)
        guard buffer.count >= sizeOffset + 4 else { return nil }
        let type = buffer[1] >> 4
        let isJSON = (buffer[2] >> 4) == 0x1
        var event: Int32?
        if headerSize >= 8 {
            var raw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer.copyBytes(to: $0, from: 4..<8) }
            event = Int32(bigEndian: raw)
        }
        var sequence: UInt32?
        if hasSequence {
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer.copyBytes(to: $0, from: headerSize..<(headerSize + 4)) }
            sequence = UInt32(bigEndian: raw)
        }
        var size: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &size) { buffer.copyBytes(to: $0, from: sizeOffset..<(sizeOffset + 4)) }
        let payloadSize = Int(UInt32(bigEndian: size))
        let total = sizeOffset + 4 + payloadSize
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: (sizeOffset + 4)..<total)
        return (DecodedFrame(type: type, flags: flags, isJSON: isJSON, event: event, sequence: sequence, payload: payload), total)
    }
}

// MARK: - Shared WebSocket plumbing

/// Reads WebSocket messages into a byte buffer and yields complete
/// Volcano frames. One instance per connection. An actor because the
/// receive loop and the socket live on different tasks.
actor VolcanoSocketReader {
    private let task: URLSessionWebSocketTask
    private var buffer = Data()

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    /// Returns the next complete frame, or nil when the socket closes.
    func nextFrame() async -> VolcanoFrame.DecodedFrame? {
        while true {
            if let decoded = VolcanoFrame.decodeFirst(from: buffer) {
                buffer.removeFirst(decoded.consumed)
                return decoded.frame
            }
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    buffer.append(data)
                case .string(let text):
                    buffer.append(Data(text.utf8))
                @unknown default:
                    break
                }
            } catch {
                return nil
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

// MARK: - Streaming ASR 2.0

/// Streaming speech recognition. Call `start` to get a stream of
/// (text, isFinal) updates, feed 16 kHz mono 16-bit PCM with `sendAudio`,
/// then `finish` to wait for the final transcript.
public actor VolcanoASRClient {
    private let config: VolcanoVoiceConfig
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var reader: VolcanoSocketReader?
    private var receiveTask: Task<Void, Never>?
    private var transcript = ""
    private var isFinal = false
    private var streamContinuation: AsyncStream<(String, Bool)>.Continuation?
    private var finalContinuation: CheckedContinuation<String, Error>?

    public init(config: VolcanoVoiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Connects, sends the full request, and returns a stream of
    /// transcript updates (partial while speaking, final at the end).
    public func start() async throws -> AsyncStream<(String, Bool)> {
        guard config.isComplete else { throw VolcanoVoiceError.notConfigured }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        let task = session.webSocketTask(with: request)
        socketTask = task
        reader = VolcanoSocketReader(task: task)
        task.resume()
        let payload = try JSONSerialization.data(withJSONObject: fullRequestJSON(), options: [])
        try await task.send(.data(VolcanoFrame.encode(type: VolcanoFrame.fullClientRequest, flags: 0, jsonPayload: payload)))
        transcript = ""
        isFinal = false
        let (stream, continuation) = AsyncStream<(String, Bool)>.makeStream()
        streamContinuation = continuation
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        return stream
    }

    public func sendAudio(_ pcm: Data) async throws {
        guard let task = socketTask else { throw VolcanoVoiceError.connectionFailed("ASR socket is not connected") }
        try await task.send(.data(VolcanoFrame.encode(type: VolcanoFrame.audioOnlyRequest, flags: 0, jsonPayload: nil, rawPayload: pcm)))
    }

    /// Stops sending audio and waits for the final transcript (up to 8s).
    /// With VAD segmentation the server marks utterances definite on its
    /// own; it sends no explicit session-final message, so after 8s the
    /// last transcript is returned as-is.
    public func finish() async throws -> String {
        if isFinal { return transcript }
        return try await withCheckedThrowingContinuation { continuation in
            finalContinuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(8))
                await self.finishTimedOut()
            }
        }
    }

    public func cancel() async {
        finalContinuation?.resume(throwing: CancellationError())
        finalContinuation = nil
        streamContinuation?.finish()
        streamContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        await reader?.cancel()
        socketTask = nil
    }

    private func finishTimedOut() {
        guard let continuation = finalContinuation else { return }
        finalContinuation = nil
        continuation.resume(returning: transcript)
    }

    private func fullRequestJSON() -> [String: Any] {
        [
            "user": ["uid": UUID().uuidString],
            "audio": ["format": "pcm", "rate": 16000, "bits": 16, "channel": 1, "codec": "raw"],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true,
                "result_type": "full",
                "vad_segment": true
            ]
        ]
    }

    /// Pure parser for one ASR server result object (the `result` dict of
    /// a type-0x9 frame), extracted so the cumulative-text / definite /
    /// prefetch rules are unit-testable. Returns nil for messages that
    /// carry no usable transcript (e.g. the session ack, which only has
    /// `additions.log_id`). Rules, verified against live traffic
    /// 2026-11-25: text is cumulative (each message holds the full text
    /// so far); an utterance is final when its `definite` is true; a
    /// `prefetch` message is the server's re-recognition pass and is
    /// never final; there is no explicit session-final message.
    public static func parseASRResult(_ result: [String: Any]) -> (text: String, isFinal: Bool)? {
        let text = result["text"] as? String ?? ""
        let utterances = result["utterances"] as? [[String: Any]] ?? []
        let isPrefetch = (result["prefetch"] as? Bool) ?? false
        let definite = !utterances.isEmpty && utterances.allSatisfy { ($0["definite"] as? Bool) == true }
        let isFinal = !isPrefetch && ((result["is_final"] as? Bool) ?? definite)
        guard !text.isEmpty || isFinal else { return nil }
        return (text, isFinal)
    }

    private func receiveLoop() async {
        guard let reader else { return }
        while let frame = await reader.nextFrame() {
            if frame.type == VolcanoFrame.serverError {
                let message = VolcanoASRClient.errorMessage(from: frame.payload)
                streamContinuation?.yield((transcript, false))
                streamContinuation?.finish()
                streamContinuation = nil
                if let continuation = finalContinuation {
                    finalContinuation = nil
                    continuation.resume(throwing: VolcanoVoiceError.serverError(-1, message))
                }
                return
            }
            guard frame.isJSON,
                  let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { continue }
            if let code = object["code"] as? Int, code != 0 {
                let message = object["message"] as? String ?? "unknown error"
                streamContinuation?.finish()
                streamContinuation = nil
                if let continuation = finalContinuation {
                    finalContinuation = nil
                    continuation.resume(throwing: VolcanoVoiceError.serverError(code, message))
                }
                return
            }
            guard let result = object["result"] as? [String: Any],
                  let update = Self.parseASRResult(result) else { continue }
            let (text, final) = update
            transcript = text
            isFinal = final
            streamContinuation?.yield((text, final))
            if final, let continuation = finalContinuation {
                finalContinuation = nil
                continuation.resume(returning: text)
            }
        }
        // Socket closed without a final result: hand back what we have
        // instead of leaving finish() hanging.
        streamContinuation?.finish()
        streamContinuation = nil
        if let continuation = finalContinuation {
            finalContinuation = nil
            continuation.resume(returning: transcript)
        }
    }

    static func errorMessage(from payload: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return String(data: payload, encoding: .utf8) ?? "unknown error"
    }
}

// MARK: - TTS 2.0 (V3 async API, verified working 2026-11-25)

/// Text to speech over the V3 async API: submit, poll query, download
/// the signed MP3 link. Verified end to end: "你好，世界" took ~9s and
/// returned a 32904-byte MP3 (1.632s of audio).
public actor VolcanoTTSClient {
    /// Default voice, verified with the submit API.
    public static let defaultSpeaker = "zh_female_gaolengyujie_uranus_bigtts"

    private let config: VolcanoVoiceConfig
    private let session: URLSession

    public init(config: VolcanoVoiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Synthesizes `text` and returns the MP3 audio data. `speaker` is
    /// any Doubao 2.0 voice id (see `DoubaoSpeaker`); `speechRate` is a
    /// playback multiplier 0.5–2.0, mapped to the API's speech_rate int
    /// [-50, 100] (0 = normal).
    public func synthesize(text: String, speaker: String = defaultSpeaker, speechRate: Double = 1.0) async throws -> Data {
        guard config.isComplete else { throw VolcanoVoiceError.notConfigured }
        let taskID = try await submit(text: text, speaker: speaker, speechRate: speechRate)
        let audioURL = try await waitForAudio(taskID: taskID)
        guard let url = URL(string: audioURL) else { throw VolcanoVoiceError.invalidResponse }
        // The signed link expires in 1 hour; download it immediately.
        let (data, _) = try await session.data(from: url)
        guard !data.isEmpty else { throw VolcanoVoiceError.invalidResponse }
        return data
    }

    private func submit(text: String, speaker: String, speechRate: Double) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/submit")!)
        request.httpMethod = "POST"
        setAuthHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "unique_id": UUID().uuidString,
            "namespace": "BidirectionalTTS",
            "req_params": [
                "text": text,
                "speaker": speaker,
                "audio_params": ["format": "mp3", "sample_rate": 24000, "speech_rate": VoiceSettings.speechRateParam(for: speechRate), "loudness_rate": 0]
            ]
        ]
        // NOTE: do not add an `additions` field (explicit_language): the
        // server rejects it with a parameter error.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VolcanoVoiceError.connectionFailed("TTS submit HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try Self.parseSubmitResponse(data)
    }

    /// Polls query once a second until the task succeeds or fails.
    /// Verified short texts finish in ~9s; give up at 120s.
    private func waitForAudio(taskID: String) async throws -> String {
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            let (status, audioURL) = try await query(taskID: taskID)
            switch status {
            case 2:
                guard let url = audioURL, !url.isEmpty else { throw VolcanoVoiceError.invalidResponse }
                return url
            case 3:
                throw VolcanoVoiceError.serverError(3, "TTS task failed")
            default:
                continue
            }
        }
        throw VolcanoVoiceError.timeout
    }

    private func query(taskID: String) async throws -> (status: Int, audioURL: String?) {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/query")!)
        request.httpMethod = "POST"
        setAuthHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["task_id": taskID], options: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VolcanoVoiceError.connectionFailed("TTS query HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try Self.parseQueryResponse(data)
    }

    private func setAuthHeaders(_ request: inout URLRequest) {
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Id")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue("seed-tts-2.0", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
    }

    /// submit returns `{"code": 20000000, "data": {"task_id": ...,
    /// "task_status": 1}}`. The task id lives under `data`, not at the
    /// top level. Pure function, covered by unit tests.
    public static func parseSubmitResponse(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? Int, code == 20000000,
              let inner = object["data"] as? [String: Any],
              let taskID = inner["task_id"] as? String, !taskID.isEmpty else {
            throw VolcanoVoiceError.invalidResponse
        }
        return taskID
    }

    /// query returns `{"code": 20000000, "data": {"task_status": 1|2|3,
    /// "audio_url": ...}}`. task_status: 1 running, 2 success, 3 failed.
    /// Pure function, covered by unit tests.
    public static func parseQueryResponse(_ data: Data) throws -> (status: Int, audioURL: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? Int, code == 20000000,
              let inner = object["data"] as? [String: Any],
              let status = inner["task_status"] as? Int else {
            throw VolcanoVoiceError.invalidResponse
        }
        return (status, inner["audio_url"] as? String)
    }
}

// MARK: - Audio playback

/// Plays audio data (MP3 from the TTS service) with AVAudioPlayer.
/// Playback methods are main-actor isolated because AVAudioPlayer is a
/// UI-thread object; the initializer is not, so views can hold one as a
/// stored property.
public final class AudioPlayer {
    private var player: AVAudioPlayer?

    public init() {}

    @MainActor public func play(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        player?.prepareToPlay()
        player?.play()
    }

    @MainActor public var isPlaying: Bool { player?.isPlaying == true }

    @MainActor public func stop() {
        player?.stop()
        player = nil
    }
}
