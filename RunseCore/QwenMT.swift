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
///   terms) goes in `extra_body` — it is not a standard OpenAI field.
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
    /// The app's target language is "中文" or "English".
    public static func languageCode(for targetLanguage: String) -> String {
        targetLanguage == "中文" ? "Chinese" : "English"
    }
}

/// The DashScope API key lives in the keychain (service
/// `Zhiyin.DashScopeAPIKey`, account `default`). It is never written
/// into code or config files. Without it the Qwen-MT options show as
/// "needs key" and the backup is unavailable.
public enum DashScopeStore {
    public static let apiKeyService = "Zhiyin.DashScopeAPIKey"
    public static let account = "default"

    public static func loadKey() async -> String? {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        guard let key = try? await keychain.load(service: apiKeyService, account: account),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key
    }

    public static func saveKey(_ key: String) async throws {
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        try await keychain.save(key, service: apiKeyService, account: account)
    }

    public static func hasKey() async -> Bool {
        await loadKey() != nil
    }
}

/// Resolves the configured Qwen-MT backup: the seeded Qwen-MT Flash
/// profile plus a saved DashScope key. Returns nil when either is
/// missing, in which case translation has no fallback.
public enum QwenMTBackup {
    public static func resolve(profiles: [ProviderProfile]) async -> (profile: ProviderProfile, apiKey: String)? {
        guard let profile = profiles.first(where: { $0.id == QwenMT.flashProfileID })
                ?? profiles.first(where: { $0.isQwenMT }) else { return nil }
        guard let apiKey = await DashScopeStore.loadKey() else { return nil }
        return (profile, apiKey)
    }
}
