import Foundation

/// Tongyi Qwen-MT (通义千问翻译专科模型) as the backup translator:
/// when DeepSeek is down, Qwen-MT takes over for the same segment.
/// Verified against the Alibaba Cloud Model Studio docs 2026-11-25:
/// - OpenAI-compatible endpoint, Beijing default:
///   `https://dashscope.aliyuncs.com/compatible-mode/v1`
/// - Models: `qwen-mt-flash` (balanced, default) and `qwen-mt-plus`
///   (highest quality). Both support streaming.
/// - The request must contain exactly ONE user message with the text;
///   no system message. `translation_options` (source_lang, target_lang,
///   terms) is a TOP-LEVEL request-body field (M2 — the official curl
///   example sends it there; the earlier `extra_body` reading came from
///   the Python SDK, which merges it to the top level, and was wrong
///   for a raw HTTP call).
/// - Streaming: Flash is incremental (each chunk adds text); Plus is
///   non-incremental (each chunk is the full translation so far) per
///   third-party docs — M3 handles Plus by replacing, not appending.
///   Not yet verified against a real key: 待真机验证.
/// - Context 16K, max output 8K tokens. Segments are capped well below
///   that so a segment can never overflow the output budget.
/// - The DashScope API key is per-region; a Beijing key only works with
///   the Beijing endpoint above.
public enum QwenMT {
    public static let baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    public static let flashModel = "qwen-mt-flash"
    public static let plusModel = "qwen-mt-plus"
    public static let flashProfileID = "qwen-mt-flash-1"
    public static let plusProfileID = "qwen-mt-plus-1"

    /// Segment ceiling for Qwen-MT calls: 1500 chars. Worst case the
    /// translation expands ~2x, so output stays well under the 8K
    /// token cap. DeepSeek's cap is 384K tokens, so it keeps the
    /// default 800-char segments.
    public static let maxSegmentChars = 1500

    /// Qwen-MT wants English language names ("Chinese", "English").
    /// S20: the old version mapped everything that was not "中文"
    /// to English — an extension target of Japanese silently became
    /// an English translation. Known languages map to their proper
    /// names; anything else throws instead of mistranslating.
    public static func languageCode(for targetLanguage: String) throws -> String {
        switch targetLanguage {
        case "中文", "Simplified Chinese", "Traditional Chinese", "Chinese":
            return "Chinese"
        case "English":
            return "English"
        case "Japanese":
            return "Japanese"
        case "Korean":
            return "Korean"
        case "Spanish":
            return "Spanish"
        case "French":
            return "French"
        case "German":
            return "German"
        default:
            throw LLMProviderError.unsupported("Qwen-MT 不支持目标语言“\(targetLanguage)”（只支持中、英、日、韩、西、法、德），请换 DeepSeek。")
        }
    }
}

/// The DashScope API key lives in the keychain (service
/// `Zhiyin.DashScopeAPIKey`, account `default`). It is never written
/// into code or config files. Without it the Qwen-MT options show as
/// "needs key" and the backup is unavailable.
public enum DashScopeStore {
    public static let apiKeyService = "Zhiyin.DashScopeAPIKey"
    public static let workspaceIDService = "Zhiyin.DashScopeWorkspaceID"
    public static let account = "default"

    public static func loadKey() async -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let key = try? await keychain.load(service: apiKeyService, account: account),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key
    }

    /// S6: throwing variant (see ProviderKeyStore.loadKeyThrowing) —
    /// a keychain fault must read as a read failure, not as "key not
    /// configured".
    public static func loadKeyThrowing() async throws -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let key = try await keychain.load(service: apiKeyService, account: account),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key
    }

    public static func saveKey(_ key: String) async throws {
        // Trim like ProviderKeyStore does: a pasted key with a
        // trailing newline would otherwise break the Authorization
        // header. An empty-after-trim key is not saved.
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(trimmed, service: apiKeyService, account: account)
    }

    public static func hasKey() async -> Bool {
        await loadKey() != nil
    }

    /// The Model Studio workspace ID (console → Workspace Details).
    /// Needed for the workspace-specific audio domains; when empty the
    /// legacy dashscope.aliyuncs.com domain is used instead (still
    /// functional per the docs).
    public static func loadWorkspaceID() async -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let id = try? await keychain.load(service: workspaceIDService, account: account),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }

    public static func saveWorkspaceID(_ id: String) async throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // S20: validate at entry — an invalid ID must never reach a
        // request host (see QwenAudio.isValidWorkspaceID).
        guard QwenAudio.isValidWorkspaceID(trimmed) else { throw QwenVoiceError.invalidWorkspaceID }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(trimmed, service: workspaceIDService, account: account)
    }

    /// S18: a mistyped workspace ID had no way back — saving empty
    /// was a silent no-op and the button was disabled on empty.
    /// Deleting returns the app to the default domain.
    public static func clearWorkspaceID() async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.delete(service: workspaceIDService, account: account)
    }
}

/// Resolves the configured Qwen-MT backup: the seeded Qwen-MT Flash
/// profile plus a saved DashScope key. Returns nil when the key is
/// missing, in which case translation has no fallback.
///
/// Takes no profiles argument on purpose: the backup profile is the
/// fixed seeded one (`ProviderProfile.qwenMTFlash()`), so callers
/// never have to send main-actor `@Query` state across to this
/// nonisolated function (Swift 6 would reject that).
public enum QwenMTBackup {
    public static func resolve() async -> (profile: ProviderProfile, apiKey: String)? {
        guard let apiKey = await DashScopeStore.loadKey() else { return nil }
        return (ProviderProfile.qwenMTFlash(), apiKey)
    }
}
