import AVFoundation
import Foundation

/// Doubao voice (Volcano engine) streaming ASR 2.0 and TTS 2.0.
///
/// Protocol, per the Volcano "豆包语音" docs:
/// - ASR: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`, auth
///   headers `X-Api-App-Key` (AppID), `X-Api-Access-Key` (Access Token),
///   `X-Api-Resource-Id: volc.seedasr.sauc.duration`, `X-Api-Request-Id`
///   (UUID), `X-Api-Sequence: -1`. Binary frames: byte 0 `0x11`
///   (protocol v1, 4-byte header), byte 1 message type (0x1 full client
///   request, 0x2 audio only, 0x9 full server response, 0xF server error)
///   plus flags, byte 2 serialization (0 raw, 1 JSON) plus compression,
///   byte 3 reserved, then a 4-byte big-endian payload size and payload.
/// - TTS: `wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream`,
///   headers `X-Api-Key`, `X-Api-Resource-Id: seed-tts-2.0`,
///   `X-Api-Request-Id`. One JSON frame carries the text; the server
///   streams raw PCM audio frames back. A finish frame (flags `0b100`)
///   closes the connection.
///
/// The AppID and Access Token live in the keychain (services
/// `Zhiyin.VolcanoAppID` / `Zhiyin.VolcanoAccessToken`, account
/// `default`). They are never written into code or config files. Without
/// them the voice UI reports "not configured" and refuses to start.
///
/// NOTE: this code is written from the public protocol docs and has not
/// been exercised against the live service (no Access Token has been
/// retrieved yet). Treat the first live call as the real test.
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
        public var payload: Data
    }

    /// Decodes the first complete frame in `buffer`, returning it and the
    /// number of bytes consumed, or nil when the buffer holds no complete
    /// frame yet.
    public static func decodeFirst(from buffer: Data) -> (frame: DecodedFrame, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let headerSize = Int(buffer[0] & 0x0F) * 4
        guard buffer.count >= headerSize + 4 else { return nil }
        let type = buffer[1] >> 4
        let flags = buffer[1] & 0x0F
        let isJSON = (buffer[2] >> 4) == 0x1
        var event: Int32?
        if headerSize >= 8 {
            var raw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer.copyBytes(to: $0, from: 4..<8) }
            event = Int32(bigEndian: raw)
        }
        var size: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &size) { buffer.copyBytes(to: $0, from: headerSize..<(headerSize + 4)) }
        let payloadSize = Int(UInt32(bigEndian: size))
        let total = headerSize + 4 + payloadSize
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: (headerSize + 4)..<total)
        return (DecodedFrame(type: type, flags: flags, isJSON: isJSON, event: event, payload: payload), total)
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
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel")!)
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
    /// With VAD segmentation the server emits final results per utterance
    /// on its own; closing the socket is the end signal.
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
            guard let result = object["result"] as? [String: Any] else { continue }
            let text = result["text"] as? String ?? ""
            let definite = (result["utterances"] as? [[String: Any]])?.allSatisfy { ($0["definite"] as? Bool) == true } ?? false
            let final = (result["is_final"] as? Bool) ?? (object["is_final"] as? Bool) ?? definite
            if !text.isEmpty || final {
                transcript = text
                isFinal = final
                streamContinuation?.yield((text, final))
            }
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

// MARK: - Streaming TTS 2.0

/// One-shot text to speech over the unidirectional streaming endpoint.
/// Returns raw PCM (24 kHz, mono, 16-bit) for playback.
public actor VolcanoTTSClient {
    private let config: VolcanoVoiceConfig
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?

    public init(config: VolcanoVoiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func synthesize(text: String) async throws -> Data {
        guard config.isComplete else { throw VolcanoVoiceError.notConfigured }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/tts/unidirectional/stream")!)
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Key")
        request.setValue("seed-tts-2.0", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        let task = session.webSocketTask(with: request)
        socketTask = task
        let reader = VolcanoSocketReader(task: task)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            socketTask = nil
        }
        let payload = try JSONSerialization.data(withJSONObject: requestJSON(text: text), options: [])
        try await task.send(.data(VolcanoFrame.encode(type: 0x1, flags: 0, jsonPayload: payload)))
        let audio = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.collectAudio(reader: reader) }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw VolcanoVoiceError.timeout
            }
            guard let result = try await group.next() else { throw VolcanoVoiceError.timeout }
            group.cancelAll()
            return result
        }
        // Send the finish frame, then close.
        try? await task.send(.data(VolcanoFrame.encode(type: 0x1, flags: 0b100, jsonPayload: Data())))
        guard !audio.isEmpty else { throw VolcanoVoiceError.invalidResponse }
        return audio
    }

    /// Collects raw audio frames until the socket closes. JSON frames are
    /// control messages: a non-zero code is a server error.
    private static func collectAudio(reader: VolcanoSocketReader) async throws -> Data {
        var audio = Data()
        while let frame = await reader.nextFrame() {
            if frame.isJSON {
                if let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                   let code = object["code"] as? Int, code != 0 {
                    throw VolcanoVoiceError.serverError(code, object["message"] as? String ?? "unknown error")
                }
                continue
            }
            audio.append(frame.payload)
        }
        return audio
    }

    private func requestJSON(text: String) -> [String: Any] {
        [
            "user": ["uid": UUID().uuidString],
            "namespace": "BidirectionalTTS",
            "req_params": [
                "text": text,
                "text_type": "plain",
                "audio_params": ["format": "pcm", "sample_rate": 24000]
            ]
        ]
    }
}

// MARK: - PCM playback

/// Plays raw PCM (mono, 16-bit) by wrapping it in a WAV header for
/// AVAudioPlayer. Playback methods are main-actor isolated because
/// AVAudioPlayer is a UI-thread object; the initializer is not, so views
/// can hold one as a stored property.
public final class PCMPlayer {
    private var player: AVAudioPlayer?

    public init() {}

    @MainActor public func play(pcm: Data, sampleRate: Int) throws {
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(uint32LE(UInt32(36 + pcm.count)))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(uint32LE(16))
        wav.append(uint16LE(1))
        wav.append(uint16LE(1))
        wav.append(uint32LE(UInt32(sampleRate)))
        wav.append(uint32LE(UInt32(sampleRate * 2)))
        wav.append(uint16LE(2))
        wav.append(uint16LE(16))
        wav.append("data".data(using: .ascii)!)
        wav.append(uint32LE(UInt32(pcm.count)))
        wav.append(pcm)
        player = try AVAudioPlayer(data: wav)
        player?.prepareToPlay()
        player?.play()
    }

    @MainActor public var isPlaying: Bool { player?.isPlaying == true }

    @MainActor public func stop() {
        player?.stop()
        player = nil
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: 4)
    }

    private func uint16LE(_ value: UInt16) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: 2)
    }
}
