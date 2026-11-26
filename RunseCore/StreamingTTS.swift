import AVFoundation
import Foundation

/// Streaming TTS over the Volcano V3 bidirectional WebSocket
/// (`wss://openspeech.bytedance.com/api/v3/tts/bidirection`).
///
/// Verified live 2026-11-25 from this VM: "你好，世界" → first audio
/// 557 ms, 75,400 bytes of 24 kHz PCM (1.571 s), vs ~9 s for the async
/// submit/query API. The sequential interpretation line and the voice
/// screen use this so speech starts while the text is still arriving
/// ("边翻边念"); the async API stays as the fallback.
///
/// Protocol (official `protocols.py`, `Message` class — read, not run):
/// 4-byte header `[0x11, (type<<4)|flag, (ser<<4)|comp, 0]`, then
/// - a 4-byte sequence number when flag bits 0–1 are 01 or 11
///   (never set by the TTS frames we send or receive),
/// - a 4-byte big-endian event number when flag bit 0x4 is set,
/// - a session id (uint32 length + UTF-8 bytes) when the event is
///   NOT one of StartConnection(1), FinishConnection(2),
///   ConnectionStarted(50), ConnectionFailed(51), ConnectionFinished(52),
/// - a connect id (uint32 length + bytes) when the event IS one of
///   ConnectionStarted(50), ConnectionFailed(51), ConnectionFinished(52),
/// - the payload (uint32 length + bytes; JSON for control frames, raw
///   PCM for audio frames).
///
/// The official demo has a real bug here: it tests `flag == WithEvent`
/// with equality, but server audio frames carry flag 6
/// (LastNoSeq|WithEvent), so its parser misreads them. This codec
/// tests the bits (`flag & 0x4`), which handles both flag 4 and flag 6.
///
/// Client frames are all type FullClientRequest (0x1) with flag 0x4
/// and a JSON payload: StartConnection (event 1, payload `{}`),
/// StartSession (100, session id, user/namespace/req_params),
/// TaskRequest (200, session id, event + req_params.text — the whole
/// text in one request; the demo sends it char by char, the server
/// accepts a single request just as well, verified live),
/// FinishSession (102, payload `{}`), FinishConnection (2, `{}`).
public enum VolcanoTTSEvent: Int32, Sendable {
    case startConnection = 1
    case finishConnection = 2
    case connectionStarted = 50
    case connectionFailed = 51
    case connectionFinished = 52
    case startSession = 100
    case cancelSession = 101
    case finishSession = 102
    case sessionStarted = 150
    case sessionCanceled = 151
    case sessionFinished = 152
    case sessionFailed = 153
    case taskRequest = 200
    case sentenceStart = 350
    case sentenceEnd = 351
    case ttsResponse = 352
    case ttsEnded = 359
}

/// Binary frame codec for the TTS bidirection protocol. Pure functions,
/// covered by unit tests (including the flag-6 audio frame the official
/// demo misparses).
public enum VolcanoTTSFrame {
    public static let fullClientRequest: UInt8 = 0x1
    public static let fullServerResponse: UInt8 = 0x9
    public static let audioOnlyServer: UInt8 = 0xB
    public static let serverError: UInt8 = 0xF
    public static let withEvent: UInt8 = 0x4

    /// Events whose frames carry no session id (per the demo's reader).
    private static let noSessionIDEvents: Set<Int32> = [1, 2, 50, 51, 52]
    /// Events whose frames carry a connect id after the session-id slot.
    private static let connectIDEvents: Set<Int32> = [50, 51, 52]

    public struct DecodedFrame: Sendable, Equatable {
        public var type: UInt8
        public var flags: UInt8
        public var isJSON: Bool
        public var event: Int32?
        public var sessionID: String?
        public var connectID: String?
        public var sequence: Int32?
        public var payload: Data
    }

    /// Encodes one client frame. Client frames always carry an event
    /// (flag 0x4) and, except for connection events, a session id.
    public static func encode(type: UInt8, event: Int32, sessionID: String?, payload: Data, isJSON: Bool) -> Data {
        var frame = Data()
        frame.append(0x11)
        frame.append((type << 4) | withEvent)
        frame.append(isJSON ? 0x10 : 0x00)
        frame.append(0x00)
        var eventValue = event.bigEndian
        frame.append(Data(bytes: &eventValue, count: 4))
        if !noSessionIDEvents.contains(event), let sessionID {
            let idData = Data(sessionID.utf8)
            var length = UInt32(idData.count).bigEndian
            frame.append(Data(bytes: &length, count: 4))
            frame.append(idData)
        }
        var size = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(payload)
        return frame
    }

    /// Decodes the first complete frame in `buffer`, returning it and
    /// the number of bytes consumed, or nil when the buffer holds no
    /// complete frame yet.
    public static func decodeFirst(from buffer: Data) -> (frame: DecodedFrame, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let type = buffer[1] >> 4
        let flags = buffer[1] & 0x0F
        let isJSON = (buffer[2] >> 4) == 0x1
        var offset = 4
        var sequence: Int32?
        let seqBits = flags & 0x3
        if seqBits == 0x1 || seqBits == 0x3 {
            guard buffer.count >= offset + 4 else { return nil }
            var raw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer.copyBytes(to: $0, from: offset..<(offset + 4)) }
            sequence = Int32(bigEndian: raw)
            offset += 4
        }
        var event: Int32?
        if (flags & withEvent) != 0 {
            guard buffer.count >= offset + 4 else { return nil }
            var raw: Int32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer.copyBytes(to: $0, from: offset..<(offset + 4)) }
            event = Int32(bigEndian: raw)
            offset += 4
        }
        var sessionID: String?
        if let event, !noSessionIDEvents.contains(event) {
            guard buffer.count >= offset + 4 else { return nil }
            var rawLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &rawLength) { buffer.copyBytes(to: $0, from: offset..<(offset + 4)) }
            let length = Int(UInt32(bigEndian: rawLength))
            offset += 4
            guard buffer.count >= offset + length else { return nil }
            if length > 0 {
                sessionID = String(data: buffer.subdata(in: offset..<(offset + length)), encoding: .utf8)
            }
            offset += length
        }
        var connectID: String?
        if let event, connectIDEvents.contains(event) {
            guard buffer.count >= offset + 4 else { return nil }
            var rawLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &rawLength) { buffer.copyBytes(to: $0, from: offset..<(offset + 4)) }
            let length = Int(UInt32(bigEndian: rawLength))
            offset += 4
            guard buffer.count >= offset + length else { return nil }
            if length > 0 {
                connectID = String(data: buffer.subdata(in: offset..<(offset + length)), encoding: .utf8)
            }
            offset += length
        }
        guard buffer.count >= offset + 4 else { return nil }
        var rawSize: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &rawSize) { buffer.copyBytes(to: $0, from: offset..<(offset + 4)) }
        let payloadSize = Int(UInt32(bigEndian: rawSize))
        offset += 4
        guard buffer.count >= offset + payloadSize else { return nil }
        let payload = buffer.subdata(in: offset..<(offset + payloadSize))
        return (DecodedFrame(type: type, flags: flags, isJSON: isJSON, event: event, sessionID: sessionID, connectID: connectID, sequence: sequence, payload: payload), offset + payloadSize)
    }
}

// MARK: - Streaming client

/// One WebSocket connection for streaming synthesis. A connection can
/// serve many sessions (one per sentence); each `synthesize` call opens
/// a fresh session, streams its audio through `onAudio`, and returns
/// when the session finishes. The caller owns playback (see
/// `StreamingAudioPlayer`).
public actor VolcanoStreamingTTSClient {
    private let config: VolcanoVoiceConfig
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var buffer = Data()
    private var isConnected = false

    /// Milliseconds from StartSession to the first audio chunk of the
    /// last `synthesize` call. Shown on the interpretation page so the
    /// real latency is visible (verified live: ~557 ms).
    public private(set) var lastFirstAudioLatencyMs: Double?

    public init(config: VolcanoVoiceConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Opens the WebSocket and completes the connection handshake.
    public func connect() async throws {
        guard config.isComplete else { throw VolcanoVoiceError.notConfigured }
        if isConnected { return }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/tts/bidirection")!)
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue("seed-tts-2.0", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        let task = session.webSocketTask(with: request)
        socketTask = task
        buffer = Data()
        task.resume()
        try await send(type: VolcanoTTSFrame.fullClientRequest, event: 1, sessionID: nil, payload: Data("{}".utf8), isJSON: true)
        let frame = try await nextFrame(timeout: 10)
        guard frame.type == VolcanoTTSFrame.fullServerResponse,
              frame.event == VolcanoTTSEvent.connectionStarted.rawValue else {
            if frame.type == VolcanoTTSFrame.serverError || frame.event == VolcanoTTSEvent.connectionFailed.rawValue {
                throw VolcanoVoiceError.serverError(Int(frame.event ?? -1), message(from: frame.payload))
            }
            throw VolcanoVoiceError.invalidResponse
        }
        isConnected = true
    }

    /// Synthesizes `text` on a fresh session. `onAudio` receives each
    /// PCM chunk (24 kHz mono 16-bit) as it arrives; returns when the
    /// session finishes. Throws on session failure or timeout (60 s).
    public func synthesize(
        text: String,
        speaker: String = VolcanoTTSClient.defaultSpeaker,
        speechRate: Double = 1.0,
        onAudio: @escaping @MainActor (Data) -> Void
    ) async throws {
        guard isConnected, socketTask != nil else { throw VolcanoVoiceError.connectionFailed("Streaming TTS is not connected") }
        let sessionID = UUID().uuidString
        let startedAt = Date()
        var firstAudioAt: Date?
        let startPayload: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "namespace": "BidirectionalTTS",
            "event": VolcanoTTSEvent.startSession.rawValue,
            "req_params": [
                "speaker": speaker,
                "audio_params": [
                    "format": "pcm",
                    "sample_rate": 24000,
                    "speech_rate": VoiceSettings.speechRateParam(for: speechRate),
                    "loudness_rate": 0
                ]
            ]
        ]
        let startData = try JSONSerialization.data(withJSONObject: startPayload, options: [])
        try await send(type: VolcanoTTSFrame.fullClientRequest, event: VolcanoTTSEvent.startSession.rawValue, sessionID: sessionID, payload: startData, isJSON: true)
        let taskPayload: [String: Any] = [
            "user": ["uid": UUID().uuidString],
            "namespace": "BidirectionalTTS",
            "event": VolcanoTTSEvent.taskRequest.rawValue,
            "req_params": [
                "speaker": speaker,
                "text": text,
                "audio_params": [
                    "format": "pcm",
                    "sample_rate": 24000,
                    "speech_rate": VoiceSettings.speechRateParam(for: speechRate),
                    "loudness_rate": 0
                ]
            ]
        ]
        let taskData = try JSONSerialization.data(withJSONObject: taskPayload, options: [])
        try await send(type: VolcanoTTSFrame.fullClientRequest, event: VolcanoTTSEvent.taskRequest.rawValue, sessionID: sessionID, payload: taskData, isJSON: true)
        try await send(type: VolcanoTTSFrame.fullClientRequest, event: VolcanoTTSEvent.finishSession.rawValue, sessionID: sessionID, payload: Data("{}".utf8), isJSON: true)

        let deadline = Date().addingTimeInterval(60)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw VolcanoVoiceError.timeout }
            let frame = try await nextFrame(timeout: remaining)
            if frame.type == VolcanoTTSFrame.serverError {
                throw VolcanoVoiceError.serverError(-1, message(from: frame.payload))
            }
            guard let event = frame.event else { continue }
            switch event {
            case VolcanoTTSEvent.ttsResponse.rawValue:
                if firstAudioAt == nil { firstAudioAt = Date() }
                await onAudio(frame.payload)
            case VolcanoTTSEvent.sessionFinished.rawValue, VolcanoTTSEvent.ttsEnded.rawValue:
                if let firstAudioAt {
                    lastFirstAudioLatencyMs = firstAudioAt.timeIntervalSince(startedAt) * 1000
                }
                return
            case VolcanoTTSEvent.sessionFailed.rawValue:
                throw VolcanoVoiceError.serverError(Int(event), message(from: frame.payload))
            default:
                continue
            }
        }
    }

    /// Closes the connection (best effort).
    public func disconnect() {
        guard let task = socketTask else { return }
        socketTask = nil
        isConnected = false
        Task {
            try? await task.send(.data(VolcanoTTSFrame.encode(
                type: VolcanoTTSFrame.fullClientRequest,
                event: VolcanoTTSEvent.finishConnection.rawValue,
                sessionID: nil,
                payload: Data("{}".utf8),
                isJSON: true
            )))
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(type: UInt8, event: Int32, sessionID: String?, payload: Data, isJSON: Bool) async throws {
        guard let task = socketTask else { throw VolcanoVoiceError.connectionFailed("Streaming TTS socket is not connected") }
        try await task.send(.data(VolcanoTTSFrame.encode(type: type, event: event, sessionID: sessionID, payload: payload, isJSON: isJSON)))
    }

    /// Reads the next complete frame, or throws on timeout / close.
    private func nextFrame(timeout: TimeInterval) async throws -> VolcanoTTSFrame.DecodedFrame {
        guard let task = socketTask else { throw VolcanoVoiceError.connectionFailed("Streaming TTS socket is not connected") }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let decoded = VolcanoTTSFrame.decodeFirst(from: buffer) {
                buffer.removeFirst(decoded.consumed)
                return decoded.frame
            }
            guard Date() < deadline else { throw VolcanoVoiceError.timeout }
            let remaining = deadline.timeIntervalSinceNow
            let received: URLSessionWebSocketTask.Message? = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask {
                    try? await task.receive()
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(remaining))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let received else { throw VolcanoVoiceError.timeout }
            switch received {
            case .data(let data):
                buffer.append(data)
            case .string(let text):
                buffer.append(Data(text.utf8))
            @unknown default:
                break
            }
        }
    }

    private func message(from payload: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return String(data: payload, encoding: .utf8) ?? "unknown error"
    }
}

// MARK: - Streaming playback

/// Plays 24 kHz mono 16-bit PCM as it arrives, chunk by chunk, through
/// AVAudioEngine. The engine runs for the whole session; call `start`
/// once, `enqueue` per audio chunk, `stop` when the session ends.
public final class StreamingAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat

    public init() {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    @MainActor public func start() throws {
        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
    }

    @MainActor public func enqueue(_ pcm: Data) {
        guard pcm.count >= 2, let buffer = pcmBuffer(from: pcm) else { return }
        playerNode.scheduleBuffer(buffer)
    }

    @MainActor public var isPlaying: Bool { playerNode.isPlaying }

    @MainActor public func stop() {
        playerNode.stop()
        engine.stop()
    }

    private func pcmBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // N5: the buffer holds frameCount * 2 bytes. Copying
            // data.count would write 1 byte past the heap block when
            // the PCM length is odd.
            memcpy(channel, base, frameCount * 2)
        }
        return buffer
    }
}
