import Foundation

/// One glossary term, used to give a specialist model (Qwen-MT)
/// server-side term intervention via `translation_options.terms`.
public struct GlossaryTerm: Sendable, Equatable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct LLMRequest: Sendable, Equatable {
    public var action: TransformAction
    public var model: String
    public var systemPrompt: String
    public var userPrompt: String
    public var temperature: Double
    /// Target language in the app's terms ("中文" or "English").
    /// Only Qwen-MT needs it as a separate field; other providers read
    /// it from the user prompt.
    public var targetLanguage: String
    /// Filled glossary terms, for providers that support server-side
    /// term intervention (Qwen-MT). Empty for other providers.
    public var glossaryTerms: [GlossaryTerm]

    public init(action: TransformAction, model: String, systemPrompt: String, userPrompt: String, temperature: Double = 0.2, targetLanguage: String = "English", glossaryTerms: [GlossaryTerm] = []) {
        self.action = action
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.temperature = temperature
        self.targetLanguage = targetLanguage
        self.glossaryTerms = glossaryTerms
    }
}

public struct LLMResponse: Sendable, Equatable {
    public var text: String
    public var responseID: String?
    public var model: String?
    public var usage: [String: Int]

    public var promptTokens: Int {
        usage["prompt_tokens"] ?? usage["input_tokens"] ?? 0
    }

    public var completionTokens: Int {
        usage["completion_tokens"] ?? usage["output_tokens"] ?? 0
    }

    public var totalTokens: Int {
        usage["total_tokens"] ?? (promptTokens + completionTokens)
    }

    public init(text: String, responseID: String? = nil, model: String? = nil, usage: [String: Int] = [:]) {
        self.text = text
        self.responseID = responseID
        self.model = model
        self.usage = usage
    }
}

public enum LLMProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidURL
    case timeout
    case connectionLost(String)
    case invalidStatus(Int, String, TimeInterval?)
    case malformedJSON
    case emptyOutput
    /// A provider kind no code path serves any more (the Anthropic
    /// SDK path was removed: no preset and no UI can create an
    /// Anthropic-kind profile, so it was dead code).
    case unsupported(String)

    /// Chinese messages: the UI shows `errorDescription` directly,
    /// and the app is Chinese-first. 401/402/429 name the actual
    /// problem (wrong key, empty balance, rate limit) instead of a
    /// bare HTTP code.
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "没有配置 API Key，请先在设置里填写。"
        case .invalidURL: "服务地址无效，请检查模型配置。"
        case .timeout: "请求超时，请重试。"
        case .connectionLost(let message): "网络断开：\(message)"
        case .invalidStatus(let code, let body, _):
            switch code {
            case 401: "API Key 无效或已过期（401），请在设置里检查 Key。"
            case 402: "余额不足或已欠费（402），请充值后重试。"
            case 429: "请求太频繁（429），请稍等再试。"
            case -1: body.isEmpty ? "请求失败。" : body
            default: "服务返回 HTTP \(code)。\(body)"
            }
        case .malformedJSON: "服务返回的数据无法解析。"
        case .emptyOutput: "服务返回了空结果。"
        case .unsupported(let message): message
        }
    }
}

public protocol LLMProviderClient {
    @MainActor func complete(_ request: LLMRequest, onDelta: (@MainActor (String) -> Void)?) async throws -> LLMResponse
}

public extension LLMProviderClient {
    @MainActor func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await complete(request, onDelta: nil)
    }
}

public final class HTTPProviderClient: LLMProviderClient {
    private let profile: ProviderProfile
    private let apiKey: String
    private let session: URLSession

    public init(profile: ProviderProfile, apiKey: String, session: URLSession = .shared) {
        self.profile = profile
        self.apiKey = apiKey
        self.session = session
    }

    @MainActor public func complete(_ request: LLMRequest, onDelta: (@MainActor (String) -> Void)? = nil) async throws -> LLMResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey
        }
        let policy = RetryPolicy.default
        var attempt = 0
        var streamedContent = false
        while true {
            attempt += 1
            do {
                return try await performAttempt(request: request, onDelta: { content in
                    streamedContent = true
                    onDelta?(content)
                })
            } catch {
                // Only retry a call that has not streamed anything yet:
                // re-sending after partial output would duplicate text.
                let decision = RetryClassifier.decision(for: error)
                guard !streamedContent, decision.isRetryable, attempt < policy.maxAttempts else { throw error }
                if policy.stops(forServerDelay: decision.retryAfter) { throw error }
                try Task.checkCancellation()
                let delay = policy.backoffDelay(retry: attempt, retryAfter: decision.retryAfter)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    @MainActor private func performAttempt(request: LLMRequest, onDelta: (@MainActor (String) -> Void)?) async throws -> LLMResponse {
        switch profile.kind {
        case .openAICompatible:
            return try await streamOpenAIChat(request: request, onDelta: onDelta)
        case .anthropicMessages, .anthropicCompatible:
            // Removed with the SwiftAnthropic dependency: no preset and
            // no UI can create an Anthropic-kind profile, so this path
            // was unreachable dead code. Kept as an explicit error
            // rather than silently mapping it to another API shape.
            throw LLMProviderError.unsupported("该模型类型（Anthropic）暂未接入，请换 DeepSeek 或 Qwen-MT。")
        case .openAIResponses:
            // The Responses API has a substantially different schema. Keep the
            // existing one-shot path here; none of the bundled presets use it.
            return try await legacyOneShot(request: request)
        }
    }

    @MainActor private func streamOpenAIChat(request: LLMRequest, onDelta: (@MainActor (String) -> Void)?) async throws -> LLMResponse {
        let urlRequest = try ProviderRequestFactory.streamingURLRequest(profile: profile, apiKey: apiKey, request: request)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        } catch is CancellationError {
            // Never disguise cancellation as a provider error: the
            // pipeline and the PDF cancel button test for it to stop
            // cleanly instead of retrying or falling back.
            throw CancellationError()
        } catch {
            throw mapStreamingError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMProviderError.malformedJSON }
        guard (200..<300).contains(http.statusCode) else {
            let body: String
            do {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                body = String(data: errorData, encoding: .utf8) ?? ""
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw mapStreamingError(error)
            }
            throw LLMProviderError.invalidStatus(http.statusCode, body, RetrySupport.retryAfterSeconds(from: http))
        }

        var content = ""
        var reasoning = ""
        var model: String?
        var responseID: String?
        var usage: [String: Int] = [:]

        do {
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if responseID == nil { responseID = object["id"] as? String }
                if model == nil { model = object["model"] as? String }
                var contentChanged = false
                for choice in (object["choices"] as? [[String: Any]]) ?? [] {
                    guard let delta = choice["delta"] as? [String: Any] else { continue }
                    if let text = delta["content"] as? String {
                        // M3: Qwen-MT Plus streams non-incrementally —
                        // each chunk carries the full translation so far
                        // (flash is incremental). Appending Plus chunks
                        // would duplicate the text into gibberish, so a
                        // Plus chunk replaces the accumulated content.
                        // Unverified against a real key (third-party docs
                        // only): mark as 待真机验证, see QwenMT.swift.
                        if profile.isQwenMTPlus {
                            content = text
                        } else {
                            content += text
                        }
                        contentChanged = true
                    }
                    if let text = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) {
                        reasoning += text
                    }
                }
                if contentChanged, let onDelta { onDelta(content) }
                if let chunkUsage = object["usage"] as? [String: Any] {
                    usage = ProviderResponseParser.parseUsage(chunkUsage)
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapStreamingError(error)
        }

        return try finalize(content: content, reasoning: reasoning, model: model, responseID: responseID, usage: usage)
    }

    @MainActor private func legacyOneShot(request: LLMRequest) async throws -> LLMResponse {
        let urlRequest = try ProviderRequestFactory.urlRequest(profile: profile, apiKey: apiKey, request: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMProviderError.timeout
        }
        guard let http = response as? HTTPURLResponse else { throw LLMProviderError.malformedJSON }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.invalidStatus(http.statusCode, body, RetrySupport.retryAfterSeconds(from: http))
        }
        return try ProviderResponseParser.parse(data: data, kind: profile.kind)
    }

    private func finalize(content: String, reasoning: String, model: String?, responseID: String?, usage: [String: Int]) throws -> LLMResponse {
        // M4: when `content` is empty, never return the reasoning /
        // thinking text as the translation — the user would see the
        // model's chain-of-thought as if it were the translated text.
        // Throw emptyOutput so retry / fallback can take over instead.
        // `reasoning` is kept in the signature (callers still collect
        // it) but is deliberately never surfaced as the result.
        _ = reasoning
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { throw LLMProviderError.emptyOutput }
        return LLMResponse(text: trimmedContent, responseID: responseID, model: model, usage: usage)
    }

    private func mapStreamingError(_ error: Error) -> LLMProviderError {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return .timeout
            case .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed, .cannotConnectToHost:
                // -1005 / -1009 etc — show only the short localized message,
                // not the full URLError userInfo dump.
                return .connectionLost(url.localizedDescription)
            default:
                break
            }
            if let response = url.userInfo["NSURLErrorFailingURLResponseErrorKey"] as? HTTPURLResponse {
                return .invalidStatus(response.statusCode, url.localizedDescription, RetrySupport.retryAfterSeconds(from: response))
            }
            return .connectionLost(url.localizedDescription)
        }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .invalidStatus(-1, message, nil)
    }
}

public struct ProviderAPITestResult: Sendable, Equatable {
    public var message: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(message: String, promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0) {
        self.message = message
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public enum ProviderAPITester {
    @MainActor public static func test(profile: ProviderProfile, apiKey: String) async throws -> ProviderAPITestResult {
        let request = LLMRequest(
            action: .refine,
            model: profile.model,
            systemPrompt: "You are an API connectivity test. Reply with OK only.",
            userPrompt: "Reply with OK.",
            temperature: 0
        )
        let response = try await HTTPProviderClient(profile: profile, apiKey: apiKey).complete(request)
        return ProviderAPITestResult(
            message: response.text,
            promptTokens: response.promptTokens,
            completionTokens: response.completionTokens,
            totalTokens: response.totalTokens
        )
    }
}

public enum ProviderRequestFactory {
    public static func urlRequest(profile: ProviderProfile, apiKey: String, request: LLMRequest) throws -> URLRequest {
        let endpoint = endpointURL(profile: profile)
        guard let url = URL(string: endpoint) else { throw LLMProviderError.invalidURL }
        // 120s: refine on large-context models routinely takes 60–90s for a
        // single non-streamed completion since we dropped streaming. 45s left
        // users staring at a spinner that always failed.
        var urlRequest = URLRequest(url: url, timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in extraHeaders(from: profile.extraHeadersJSON) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(profile: profile, request: request), options: [])
        return urlRequest
    }

    public static func body(profile: ProviderProfile, request: LLMRequest) -> [String: Any] {
        // Thinking is disabled explicitly for DeepSeek: with thinking on,
        // DeepSeek ignores `temperature`, and reasoning models can burn
        // their entire output budget on chain-of-thought, returning empty
        // `content`. Other providers keep their server default. M4: the
        // response parser no longer falls back to `reasoning_content` /
        // Anthropic `thinking` blocks — empty content throws emptyOutput
        // instead of showing chain-of-thought as a translation.
        switch profile.kind {
        case .openAIResponses:
            return [
                "model": request.model,
                "input": [
                    ["role": "system", "content": request.systemPrompt],
                    ["role": "user", "content": request.userPrompt]
                ],
                "temperature": request.temperature
            ]
        case .anthropicMessages, .anthropicCompatible:
            return [
                "model": request.model,
                "system": request.systemPrompt,
                "messages": [
                    ["role": "user", "content": request.userPrompt]
                ],
                "temperature": request.temperature
            ]
        case .openAICompatible:
            // Qwen-MT (DashScope) has a strict shape: exactly ONE user
            // message with the text, no system message, and the language
            // pair plus glossary terms in a TOP-LEVEL
            // `translation_options` field. M2: the previous code nested
            // it under `extra_body`, which is only an OpenAI Python SDK
            // parameter mechanism — the official curl example sends
            // `translation_options` at the top level, and a raw HTTP
            // call would never reach the server's language settings.
            // Temperature is left out: Qwen-MT is a specialist model and
            // the docs do not list it as a supported parameter.
            if profile.isQwenMT {
                var options: [String: Any] = [
                    "source_lang": "auto",
                    "target_lang": QwenMT.languageCode(for: request.targetLanguage)
                ]
                if !request.glossaryTerms.isEmpty {
                    options["terms"] = request.glossaryTerms.map {
                        ["source": $0.source, "target": $0.target]
                    }
                }
                return [
                    "model": request.model,
                    "messages": [
                        ["role": "user", "content": request.userPrompt]
                    ],
                    "translation_options": options
                ]
            }
            var openAIBody: [String: Any] = [
                "model": request.model,
                "messages": [
                    ["role": "system", "content": request.systemPrompt],
                    ["role": "user", "content": request.userPrompt]
                ],
                "temperature": request.temperature
            ]
            if isDeepSeekDomain(profile) {
                openAIBody["thinking"] = ["type": "disabled"]
            }
            return openAIBody
        }
    }

    /// DeepSeek's API honors an explicit thinking toggle; its default is
    /// thinking on, which makes `temperature` ineffective.
    public static func isDeepSeekDomain(_ profile: ProviderProfile) -> Bool {
        guard let host = URL(string: profile.baseURL)?.host?.lowercased() else { return false }
        return host == "deepseek.com" || host.hasSuffix(".deepseek.com")
    }

    /// Streaming variant of `urlRequest`: same body plus `stream` and
    /// `stream_options.include_usage`, served as server-sent events.
    public static func streamingURLRequest(profile: ProviderProfile, apiKey: String, request: LLMRequest) throws -> URLRequest {
        var urlRequest = try urlRequest(profile: profile, apiKey: apiKey, request: request)
        guard profile.kind == .openAICompatible else { return urlRequest }
        var streamBody = body(profile: profile, request: request)
        streamBody["stream"] = true
        streamBody["stream_options"] = ["include_usage": true]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: streamBody, options: [])
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // 180s inactivity timeout, matching the old streaming client: with
        // streaming, deltas reset this on each chunk so it really only fires
        // when the connection truly stalls.
        urlRequest.timeoutInterval = 180
        return urlRequest
    }

    private static func endpointURL(profile: ProviderProfile) -> String {
        let base = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = profile.chatEndpoint.hasPrefix("/") ? profile.chatEndpoint : "/\(profile.chatEndpoint)"
        return "\(base)\(endpoint)"
    }

    private static func extraHeaders(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
}

public enum ProviderResponseParser {
    /// Parse a non-streamed JSON body into an `LLMResponse`.
    public static func parse(data: Data, kind: ProviderKind) throws -> LLMResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.malformedJSON
        }
        let content: String?
        let reasoning: String?
        switch kind {
        case .openAIResponses:
            content = parseResponsesText(object)
            reasoning = nil
        case .openAICompatible:
            let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            content = message?["content"] as? String
            // DeepSeek and other reasoning-capable OpenAI-compatible providers
            // surface chain-of-thought on `message.reasoning_content`. Fall back
            // to it when `content` is empty so a thinking-only response still
            // produces something useful.
            reasoning = message?["reasoning_content"] as? String
        case .anthropicMessages, .anthropicCompatible:
            let blocks = object["content"] as? [[String: Any]] ?? []
            content = blocks
                .filter { ($0["type"] as? String) != "thinking" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            reasoning = blocks
                .filter { ($0["type"] as? String) == "thinking" }
                .compactMap { $0["thinking"] as? String }
                .joined(separator: "\n")
        }
        // M4: same rule as `finalize` — empty content throws
        // emptyOutput; reasoning/thinking text is never returned as
        // the translation.
        _ = reasoning
        let trimmedContent = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedContent.isEmpty else { throw LLMProviderError.emptyOutput }
        let finalText = trimmedContent
        return LLMResponse(
            text: finalText,
            responseID: object["id"] as? String,
            model: object["model"] as? String,
            usage: parseUsage(object["usage"] as? [String: Any])
        )
    }

    private static func parseResponsesText(_ object: [String: Any]) -> String? {
        if let direct = object["output_text"] as? String { return direct }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        return output.compactMap { item in
            (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }.joined(separator: "\n")
    }

    static func parseUsage(_ usage: [String: Any]?) -> [String: Int] {
        usage?.reduce(into: [String: Int]()) { partial, item in
            if let value = item.value as? Int {
                partial[item.key] = value
            } else if let value = item.value as? Double {
                partial[item.key] = Int(value)
            }
        } ?? [:]
    }
}
