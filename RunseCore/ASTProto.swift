import Foundation

/// Minimal protobuf codec for the Seed-LiveInterpret 2.0 (同声传译 2.0)
/// WebSocket API. No third-party protobuf dependency: the AST v2 wire
/// format needs only varint, length-delimited and 32-bit float fields,
/// so a ~150-line hand codec covers it. Every encoder and decoder here
/// is pinned by fixtures generated with the official Python protogen
/// code (`/tmp/ast-ref`, Good-Interpreter) — see ASTProtoTests; if the
/// fixtures and this file disagree, the fixtures win.
///
/// Wire reference (volcengine docs 6561/1756902, `protos.tar.gz`):
/// - `wss://openspeech.bytedance.com/api/v4/ast/v2/translate`
/// - Auth headers: `X-Api-App-Key` (AppID), `X-Api-Access-Key`
///   (Access Token), `X-Api-Resource-Id: volc.service_type.10053`
///   (fixed), `X-Api-Request-Id`, `X-Api-Connect-Id`.
/// - The WebSocket carries RAW protobuf messages as binary frames —
///   no VolcanoFrame 4-byte header (unlike the ASR/TTS v1/v3 APIs).
/// - `TranslateRequest`: 1 request_meta, 2 event, 3 user,
///   4 source_audio, 5 target_audio, 6 request, 7 denoise.
/// - `TranslateResponse`: 1 response_meta, 2 event, 3 data (TTS
///   audio), 4 text (subtitle), 5 start_time, 6 end_time,
///   7 spk_chg, 8 muted_duration_ms.
/// - Events: StartSession 100, CancelSession 101, FinishSession 102,
///   SessionStarted 150, SessionCanceled 151, SessionFinished 152,
///   SessionFailed 153, UsageResponse 154, TaskRequest 200,
///   UpdateConfig 201, AudioMuted 250, TTSSentenceStart 350,
///   TTSSentenceEnd 351, TTSResponse 352, SourceSubtitleStart 650,
///   SourceSubtitleResponse 651, SourceSubtitleEnd 652,
///   TranslationSubtitleStart 653, TranslationSubtitleResponse 654,
///   TranslationSubtitleEnd 655.
/// - The service clones the speaker's voice in s2s mode by itself
///   (zero-shot); there is no voice parameter to set.
/// - A session cannot switch language or mode mid-session; changing
///   direction means reconnecting. `UpdateConfig` (201) only updates
///   corpus (hot words / glossary / corrections).
/// - Glossary is a hint, not a guarantee: the docs say `corpus.
///   glossary_list` "用来指导模型，不一定干预生效". The "术语表里的词
///   必须按术语表翻" bar is enforced on the sequential fallback path
///   (prompt injection + post-check) and on the live path by sending
///   the glossary; it cannot be forced harder than the service allows.

// MARK: - Minimal protobuf codec

public enum Protobuf {
    public enum WireType: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    public enum Field: Equatable {
        case varint(field: Int, value: UInt64)
        case bytes(field: Int, value: Data)
        case fixed32(field: Int, value: UInt32)

        public var fieldNumber: Int {
            switch self {
            case .varint(let field, _): return field
            case .bytes(let field, _): return field
            case .fixed32(let field, _): return field
            }
        }
    }

    public enum DecodeError: Error {
        case truncated
        case invalidTag
        case invalidWireType(Int)
        case invalidUTF8
    }

    public static func encodeVarint(_ value: UInt64) -> Data {
        var data = Data()
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
        return data
    }

    public static func encodeTag(field: Int, wireType: WireType) -> Data {
        encodeVarint(UInt64((field << 3) | wireType.rawValue))
    }

    public static func encodeVarintField(field: Int, value: UInt64) -> Data {
        encodeTag(field: field, wireType: .varint) + encodeVarint(value)
    }

    public static func encodeBytesField(field: Int, value: Data) -> Data {
        encodeTag(field: field, wireType: .lengthDelimited) + encodeVarint(UInt64(value.count)) + value
    }

    public static func encodeStringField(field: Int, value: String) -> Data {
        encodeBytesField(field: field, value: Data(value.utf8))
    }

    public static func encodeFloatField(field: Int, value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        let payload = Data(bytes: &bits, count: 4)
        return encodeTag(field: field, wireType: .fixed32) + payload
    }

    /// Decodes a protobuf message into its fields, in wire order.
    /// Unknown fields are kept (callers ignore them); fixed64 is
    /// skipped by length since this API never sends it.
    public static func decode(_ data: Data) throws -> [Field] {
        var fields: [Field] = []
        var offset = 0
        while offset < data.count {
            let (tag, tagEnd) = try readVarint(data, from: offset)
            offset = tagEnd
            guard tag > 0 else { throw DecodeError.invalidTag }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            switch wire {
            case WireType.varint.rawValue:
                let (value, end) = try readVarint(data, from: offset)
                fields.append(.varint(field: field, value: value))
                offset = end
            case WireType.lengthDelimited.rawValue:
                let (length, end) = try readVarint(data, from: offset)
                offset = end
                guard offset + Int(length) <= data.count else { throw DecodeError.truncated }
                fields.append(.bytes(field: field, value: data.subdata(in: offset..<(offset + Int(length)))))
                offset += Int(length)
            case WireType.fixed32.rawValue:
                guard offset + 4 <= data.count else { throw DecodeError.truncated }
                var raw: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &raw) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
                fields.append(.fixed32(field: field, value: UInt32(littleEndian: raw)))
                offset += 4
            case WireType.fixed64.rawValue:
                guard offset + 8 <= data.count else { throw DecodeError.truncated }
                offset += 8
            default:
                throw DecodeError.invalidWireType(wire)
            }
        }
        return fields
    }

    private static func readVarint(_ data: Data, from offset: Int) throws -> (UInt64, Int) {
        var value: UInt64 = 0
        var shift = 0
        var index = offset
        while true {
            guard index < data.count else { throw DecodeError.truncated }
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 70 else { throw DecodeError.invalidTag }
        }
        return (value, index)
    }
}

extension Array where Element == Protobuf.Field {
    func varint(_ field: Int) -> UInt64? {
        first { $0.fieldNumber == field }.flatMap {
            if case .varint(_, let value) = $0 { return value }
            return nil
        }
    }

    func bytes(_ field: Int) -> Data? {
        first { $0.fieldNumber == field }.flatMap {
            if case .bytes(_, let value) = $0 { return value }
            return nil
        }
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    func fixed32(_ field: Int) -> UInt32? {
        first { $0.fieldNumber == field }.flatMap {
            if case .fixed32(_, let value) = $0 { return value }
            return nil
        }
    }

    func all(_ field: Int) -> [Protobuf.Field] {
        filter { $0.fieldNumber == field }
    }
}

// MARK: - AST v2 message types

public enum ASTEvent: Int, Sendable, Equatable {
    case startSession = 100
    case cancelSession = 101
    case finishSession = 102
    case sessionStarted = 150
    case sessionCanceled = 151
    case sessionFinished = 152
    case sessionFailed = 153
    case usageResponse = 154
    case taskRequest = 200
    case updateConfig = 201
    case audioMuted = 250
    case ttsSentenceStart = 350
    case ttsSentenceEnd = 351
    case ttsResponse = 352
    case sourceSubtitleStart = 650
    case sourceSubtitleResponse = 651
    case sourceSubtitleEnd = 652
    case translationSubtitleStart = 653
    case translationSubtitleResponse = 654
    case translationSubtitleEnd = 655
}

public enum ASTMode: String, Sendable {
    case s2s
    case s2t
}

public enum ASTLanguage: String, Sendable {
    case zh
    case en
}

/// One direction of a simultaneous-interpretation session.
public struct ASTSessionConfig: Sendable, Equatable {
    public var sessionID: String
    public var userID: String
    public var deviceID: String
    public var sdkVersion: String
    public var mode: ASTMode
    public var sourceLanguage: ASTLanguage
    public var targetLanguage: ASTLanguage
    /// Ordered (source term, fixed translation) pairs, sent as
    /// corpus.glossary_list. Ordered on purpose: protobuf map entries
    /// serialize in the order given, and the fixtures pin that order.
    public var glossary: [(source: String, target: String)]
    public var hotWords: [String]
    /// s2s output audio: "pcm" is the only format AVFoundation can play
    /// without an Opus decoder. Rate 24000 (default), 16000 also works.
    public var targetAudioFormat: String
    public var targetAudioRate: Int

    public init(
        sessionID: String = UUID().uuidString,
        userID: String = "zhiyin",
        deviceID: String = "zhiyin-ios",
        sdkVersion: String = "zhiyin-1.0",
        mode: ASTMode = .s2s,
        sourceLanguage: ASTLanguage,
        targetLanguage: ASTLanguage,
        glossary: [(source: String, target: String)] = [],
        hotWords: [String] = [],
        targetAudioFormat: String = "pcm",
        targetAudioRate: Int = 24000
    ) {
        self.sessionID = sessionID
        self.userID = userID
        self.deviceID = deviceID
        self.sdkVersion = sdkVersion
        self.mode = mode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.hotWords = hotWords
        self.targetAudioFormat = targetAudioFormat
        self.targetAudioRate = targetAudioRate
    }

    public static func == (lhs: ASTSessionConfig, rhs: ASTSessionConfig) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.userID == rhs.userID
            && lhs.deviceID == rhs.deviceID
            && lhs.sdkVersion == rhs.sdkVersion
            && lhs.mode == rhs.mode
            && lhs.sourceLanguage == rhs.sourceLanguage
            && lhs.targetLanguage == rhs.targetLanguage
            && lhs.glossary.elementsEqual(rhs.glossary, by: { $0.source == $1.source && $0.target == $1.target })
            && lhs.hotWords == rhs.hotWords
            && lhs.targetAudioFormat == rhs.targetAudioFormat
            && lhs.targetAudioRate == rhs.targetAudioRate
    }
}

public enum ASTRequest {
    /// Builds a StartSession (event 100) request. Field order follows
    /// the official serialization: request_meta, event, user,
    /// source_audio, target_audio, request.
    public static func startSession(config: ASTSessionConfig) -> Data {
        var message = Data()
        message.append(requestMeta(sessionID: config.sessionID))
        message.append(Protobuf.encodeVarintField(field: 2, value: UInt64(ASTEvent.startSession.rawValue)))
        message.append(user(config: config))
        message.append(sourceAudio())
        message.append(targetAudio(config: config))
        message.append(requestParams(config: config))
        return message
    }

    /// Builds a TaskRequest (event 200) carrying one audio packet.
    /// 16kHz 16-bit mono PCM, ~80ms per packet per the docs.
    public static func taskRequest(sessionID: String, audio: Data) -> Data {
        var message = Data()
        message.append(requestMeta(sessionID: sessionID))
        message.append(Protobuf.encodeVarintField(field: 2, value: UInt64(ASTEvent.taskRequest.rawValue)))
        var audioMessage = Data()
        audioMessage.append(Protobuf.encodeBytesField(field: 14, value: audio))
        message.append(Protobuf.encodeBytesField(field: 4, value: audioMessage))
        return message
    }

    /// Builds a FinishSession (event 102) request.
    public static func finishSession(sessionID: String) -> Data {
        var message = Data()
        message.append(requestMeta(sessionID: sessionID))
        message.append(Protobuf.encodeVarintField(field: 2, value: UInt64(ASTEvent.finishSession.rawValue)))
        return message
    }

    /// Builds an UpdateConfig (event 201) request: mid-session corpus
    /// update (glossary / hot words). Language and mode cannot change
    /// mid-session, so they are not sent here.
    public static func updateConfig(sessionID: String, mode: ASTMode, glossary: [(source: String, target: String)], hotWords: [String] = []) -> Data {
        var message = Data()
        message.append(requestMeta(sessionID: sessionID))
        message.append(Protobuf.encodeVarintField(field: 2, value: UInt64(ASTEvent.updateConfig.rawValue)))
        var params = Data()
        params.append(Protobuf.encodeStringField(field: 1, value: mode.rawValue))
        params.append(corpus(glossary: glossary, hotWords: hotWords))
        message.append(Protobuf.encodeBytesField(field: 6, value: params))
        return message
    }

    private static func requestMeta(sessionID: String) -> Data {
        var meta = Data()
        meta.append(Protobuf.encodeStringField(field: 6, value: sessionID))
        return Protobuf.encodeBytesField(field: 1, value: meta)
    }

    private static func user(config: ASTSessionConfig) -> Data {
        var user = Data()
        user.append(Protobuf.encodeStringField(field: 1, value: config.userID))
        user.append(Protobuf.encodeStringField(field: 2, value: config.deviceID))
        user.append(Protobuf.encodeStringField(field: 3, value: "iOS"))
        user.append(Protobuf.encodeStringField(field: 4, value: config.sdkVersion))
        return Protobuf.encodeBytesField(field: 3, value: user)
    }

    private static func sourceAudio() -> Data {
        var audio = Data()
        audio.append(Protobuf.encodeStringField(field: 4, value: "wav"))
        audio.append(Protobuf.encodeVarintField(field: 7, value: 16000))
        audio.append(Protobuf.encodeVarintField(field: 8, value: 16))
        audio.append(Protobuf.encodeVarintField(field: 9, value: 1))
        return Protobuf.encodeBytesField(field: 4, value: audio)
    }

    private static func targetAudio(config: ASTSessionConfig) -> Data {
        var audio = Data()
        audio.append(Protobuf.encodeStringField(field: 4, value: config.targetAudioFormat))
        audio.append(Protobuf.encodeVarintField(field: 7, value: UInt64(config.targetAudioRate)))
        return Protobuf.encodeBytesField(field: 5, value: audio)
    }

    private static func requestParams(config: ASTSessionConfig) -> Data {
        var params = Data()
        params.append(Protobuf.encodeStringField(field: 1, value: config.mode.rawValue))
        params.append(Protobuf.encodeStringField(field: 2, value: config.sourceLanguage.rawValue))
        params.append(Protobuf.encodeStringField(field: 3, value: config.targetLanguage.rawValue))
        params.append(corpus(glossary: config.glossary, hotWords: config.hotWords))
        return Protobuf.encodeBytesField(field: 6, value: params)
    }

    private static func corpus(glossary: [(source: String, target: String)], hotWords: [String]) -> Data {
        var body = Data()
        for word in hotWords {
            body.append(Protobuf.encodeStringField(field: 9, value: word))
        }
        for pair in glossary {
            var entry = Data()
            entry.append(Protobuf.encodeStringField(field: 1, value: pair.source))
            entry.append(Protobuf.encodeStringField(field: 2, value: pair.target))
            body.append(Protobuf.encodeBytesField(field: 10, value: entry))
        }
        return Protobuf.encodeBytesField(field: 100, value: body)
    }
}

public struct ASTBillingItem: Sendable, Equatable {
    public var unit: String
    public var quantity: Float
}

public struct ASTBilling: Sendable, Equatable {
    public var items: [ASTBillingItem]
    /// Session duration in milliseconds.
    public var durationMsec: Int64
}

public struct ASTResponse: Sendable, Equatable {
    public var event: ASTEvent?
    public var sessionID: String?
    public var sequence: Int64?
    public var statusCode: Int32?
    public var message: String?
    public var billing: ASTBilling?
    /// TTS audio chunk (TTSResponse).
    public var data: Data?
    /// Subtitle text (subtitle events).
    public var text: String?
    /// Milliseconds, relative to the session.
    public var startTime: Int64?
    public var endTime: Int64?
    /// Speaker changed at this subtitle boundary.
    public var speakerChanged: Bool
    public var mutedDurationMs: Int64?

    public init(
        event: ASTEvent? = nil,
        sessionID: String? = nil,
        sequence: Int64? = nil,
        statusCode: Int32? = nil,
        message: String? = nil,
        billing: ASTBilling? = nil,
        data: Data? = nil,
        text: String? = nil,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        speakerChanged: Bool = false,
        mutedDurationMs: Int64? = nil
    ) {
        self.event = event
        self.sessionID = sessionID
        self.sequence = sequence
        self.statusCode = statusCode
        self.message = message
        self.billing = billing
        self.data = data
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerChanged = speakerChanged
        self.mutedDurationMs = mutedDurationMs
    }

    /// Decodes one TranslateResponse message. Returns nil when the
    /// bytes are not a decodable response.
    public static func decode(_ data: Data) -> ASTResponse? {
        guard let fields = try? Protobuf.decode(data) else { return nil }
        var response = ASTResponse()
        if let metaData = fields.bytes(1), let meta = try? Protobuf.decode(metaData) {
            response.sessionID = meta.string(1)
            if let sequence = meta.varint(2) { response.sequence = Int64(bitPattern: sequence) }
            if let code = meta.varint(3) { response.statusCode = Int32(truncatingIfNeeded: code) }
            response.message = meta.string(4)
            if let billingData = meta.bytes(5), let billingFields = try? Protobuf.decode(billingData) {
                var items: [ASTBillingItem] = []
                for itemField in billingFields.all(1) {
                    guard case .bytes(_, let itemData) = itemField,
                          let itemFields = try? Protobuf.decode(itemData),
                          let unit = itemFields.string(1),
                          let quantityBits = itemFields.fixed32(2) else { continue }
                    items.append(ASTBillingItem(unit: unit, quantity: Float(bitPattern: quantityBits)))
                }
                let duration = billingFields.varint(2).map { Int64(bitPattern: $0) } ?? 0
                response.billing = ASTBilling(items: items, durationMsec: duration)
            }
        }
        if let eventRaw = fields.varint(2) {
            response.event = ASTEvent(rawValue: Int(eventRaw))
        }
        response.data = fields.bytes(3)
        response.text = fields.string(4)
        if let start = fields.varint(5) { response.startTime = Int64(bitPattern: start) }
        if let end = fields.varint(6) { response.endTime = Int64(bitPattern: end) }
        response.speakerChanged = (fields.varint(7) ?? 0) != 0
        if let muted = fields.varint(8) { response.mutedDurationMs = Int64(bitPattern: muted) }
        return response
    }

    /// True when the server reports a non-success status code.
    public var isError: Bool {
        guard let statusCode else { return false }
        return statusCode != 20000000
    }
}
