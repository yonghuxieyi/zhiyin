import Foundation

/// "My voice" (清单 8): a fixed voice cloned from a 10–30 s recording,
/// via Alibaba Model Studio (DashScope) voice cloning.
///
/// IMPORTANT — the model line changed since the first plan. The old
/// Qwen3-TTS engine (`qwen3-tts-flash`) was switched off by Alibaba;
/// the current API is Qwen-Audio-TTS, model `qwen-audio-3.1-tts-flash`.
/// Verified against the official docs 2026-11-25:
/// - Clone: `POST {workspace}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/customization`
///   (the legacy `dashscope.aliyuncs.com` domain still works when no
///   workspace ID is saved), header `Authorization: Bearer <key>`,
///   body `{"model": "voice-enrollment", "input": {"action":
///   "create_voice", "target_model": "qwen-audio-3.1-tts-flash",
///   "prefix": "myvoice", "audio": "data:audio/wav;base64,...",
///   "language_hints": ["zh"]}}`. The Base64 audio goes in the
///   `audio` field (the legacy `url` field is being phased out).
///   `prefix` is digits + English letters, max 10 chars. Response:
///   `{"output": {"voice_id": "..."}}` — the voice id is bound to
///   its target model and cannot be used with another model.
/// - Synthesize: `POST {workspace}.cn-beijing.maas.aliyuncs.com/
///   api/v1/services/audio/tts/SpeechSynthesizer`, body
///   `{"model": "qwen-audio-3.1-tts-flash", "input": {"text": ...,
///   "voice": "<voice_id>", "format": "mp3", "sample_rate": 24000,
///   "rate": 1.0}}`. Response: `{"output": {"audio": {"url": ...}}}` —
///   download the URL promptly, it expires.
/// - Delete: same customization endpoint, `{"action": "delete_voice",
///   "voice_id": "..."}`.
/// - Audio: WAV/MP3/M4A, 10–20 s recommended (max 30 s for the prompt,
///   ≤10 MB, ≥16 kHz). The app records 16 kHz mono WAV.
///
/// Nothing here has been verified live: there is no DashScope key yet.
/// The UI shows server errors verbatim instead of pretending success.
public enum QwenVoiceError: Error, LocalizedError, Equatable {
    case notConfigured(String)
    case serverError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what): "未配置\(what)。"
        case .serverError(let message): "百炼返回错误：\(message)"
        case .invalidResponse: "百炼返回了无法解析的结果。"
        }
    }
}

public enum QwenAudio {
    /// Current Qwen-Audio-TTS flash model (clone target + synthesis).
    public static let model = "qwen-audio-3.1-tts-flash"
    public static let legacyBaseURL = "https://dashscope.aliyuncs.com"

    /// Workspace-specific base URL when the user saved a workspace ID,
    /// otherwise the legacy domain (still functional per the docs).
    public static func baseURL(workspaceID: String?) -> String {
        guard let workspaceID, !workspaceID.isEmpty else { return legacyBaseURL }
        return "https://\(workspaceID).cn-beijing.maas.aliyuncs.com"
    }

    public static func customizationURL(workspaceID: String?) -> URL? {
        URL(string: baseURL(workspaceID: workspaceID) + "/api/v1/services/audio/tts/customization")
    }

    public static func synthesizerURL(workspaceID: String?) -> URL? {
        URL(string: baseURL(workspaceID: workspaceID) + "/api/v1/services/audio/tts/SpeechSynthesizer")
    }
}

/// The cloned voice id lives in the keychain (service
/// `Zhiyin.QwenVoiceID`). It is never written into code or config.
public enum QwenVoiceStore {
    public static let voiceIDService = "Zhiyin.QwenVoiceID"
    public static let account = "default"

    public static func loadVoiceID() async -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let id = try? await keychain.load(service: voiceIDService, account: account),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }

    public static func saveVoiceID(_ id: String) async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(id, service: voiceIDService, account: account)
    }

    public static func clearVoiceID() async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.delete(service: voiceIDService, account: account)
    }
}

/// Whether "my voice" is switched on AND a cloned voice exists.
public enum MyVoice {
    public static func isEnabled() async -> Bool {
        var settings = VoiceSettings()
        guard settings.useMyVoice else { return false }
        return await QwenVoiceStore.loadVoiceID() != nil
    }
}

public enum QwenVoiceClone {
    /// Creates a cloned voice from `audioData` (WAV, 10–30 s) and
    /// returns the voice id. `prefix` becomes part of the generated
    /// voice name (`{model}-{prefix}-{id}`).
    public static func createVoice(
        apiKey: String,
        workspaceID: String?,
        audioData: Data,
        prefix: String = "myvoice",
        session: URLSession = .shared
    ) async throws -> String {
        guard let url = QwenAudio.customizationURL(workspaceID: workspaceID) else {
            throw QwenVoiceError.invalidResponse
        }
        let dataURI = "data:audio/wav;base64," + audioData.base64EncodedString()
        let body: [String: Any] = [
            "model": "voice-enrollment",
            "input": [
                "action": "create_voice",
                "target_model": QwenAudio.model,
                "prefix": prefix,
                "audio": dataURI,
                "language_hints": ["zh"]
            ]
        ]
        let data = try await postJSON(url: url, apiKey: apiKey, body: body, session: session)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenVoiceError.invalidResponse
        }
        if let output = object["output"] as? [String: Any],
           let voiceID = output["voice_id"] as? String, !voiceID.isEmpty {
            return voiceID
        }
        throw QwenVoiceError.serverError(serverMessage(from: object))
    }

    /// Deletes a cloned voice server-side.
    public static func deleteVoice(
        apiKey: String,
        workspaceID: String?,
        voiceID: String,
        session: URLSession = .shared
    ) async throws {
        guard let url = QwenAudio.customizationURL(workspaceID: workspaceID) else {
            throw QwenVoiceError.invalidResponse
        }
        let body: [String: Any] = [
            "model": "voice-enrollment",
            "input": ["action": "delete_voice", "voice_id": voiceID]
        ]
        let data = try await postJSON(url: url, apiKey: apiKey, body: body, session: session)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenVoiceError.invalidResponse
        }
        if object["output"] != nil { return }
        throw QwenVoiceError.serverError(serverMessage(from: object))
    }

    /// Synthesizes `text` with the cloned voice and returns the audio
    /// data (MP3, 24 kHz). The response carries a download URL; it is
    /// fetched immediately because it expires.
    public static func synthesize(
        apiKey: String,
        workspaceID: String?,
        text: String,
        voiceID: String,
        rate: Double = 1.0,
        session: URLSession = .shared
    ) async throws -> Data {
        guard let url = QwenAudio.synthesizerURL(workspaceID: workspaceID) else {
            throw QwenVoiceError.invalidResponse
        }
        let body: [String: Any] = [
            "model": QwenAudio.model,
            "input": [
                "text": text,
                "voice": voiceID,
                "format": "mp3",
                "sample_rate": 24000,
                "rate": min(2.0, max(0.5, rate))
            ]
        ]
        let data = try await postJSON(url: url, apiKey: apiKey, body: body, session: session)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any],
              let audioURLString = audio["url"] as? String,
              let audioURL = URL(string: audioURLString) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                throw QwenVoiceError.serverError(serverMessage(from: object))
            }
            throw QwenVoiceError.invalidResponse
        }
        let (audioData, _) = try await session.data(from: audioURL)
        guard !audioData.isEmpty else { throw QwenVoiceError.invalidResponse }
        return audioData
    }

    private static func postJSON(url: URL, apiKey: String, body: [String: Any], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                throw QwenVoiceError.serverError(serverMessage(from: object))
            }
            throw QwenVoiceError.serverError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    /// DashScope error shape: `{"code": "...", "message": "..."}`.
    /// Pure function, covered by unit tests.
    public static func serverMessage(from object: [String: Any]) -> String {
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let code = object["code"] as? String, !code.isEmpty { return code }
        return "未知错误"
    }
}
