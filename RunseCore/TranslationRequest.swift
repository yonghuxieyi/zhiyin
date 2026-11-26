import Foundation

/// One resolved translation call: the profile, its key, and the
/// template. The six screens that translate text (text, voice,
/// photo, face-to-face, live camera, PDF) all did the same three
/// steps inline — pick the default profile, load its key from the
/// keychain, pick the translate template — and any fix to one step
/// had to be repeated six times. This is the single entry point.
/// Deliberately NOT Sendable: `profile` and `template` are SwiftData
/// @Model classes — mutable reference types bound to a model context,
/// so they cannot honestly conform to Sendable (their stored
/// properties are all `var`; `@unchecked Sendable` would be a lie).
/// No Sendable is needed: `resolve` is @MainActor, all seven call
/// sites are @MainActor views, and `TranslationPipeline.translate`
/// is @MainActor, so a context never crosses an isolation boundary.
public struct TranslationRequestContext {
    public var profile: ProviderProfile
    public var apiKey: String
    public var template: PromptTemplate

    public init(profile: ProviderProfile, apiKey: String, template: PromptTemplate) {
        self.profile = profile
        self.apiKey = apiKey
        self.template = template
    }
}

public enum TranslationRequestResolver {
    /// Resolves the profile (the given id, else the default, else
    /// the first), its keychain key, and the translate template.
    /// Throws `missingAPIKey` when the profile has no key and
    /// `invalidURL` when there is no profile at all. The key is
    /// trimmed: a pasted key with a trailing newline would otherwise
    /// break the Authorization header.
    @MainActor public static func resolve(
        profiles: [ProviderProfile],
        templates: [PromptTemplate],
        profileID: String? = nil
    ) async throws -> TranslationRequestContext {
        guard let profile = (profileID.flatMap { id in profiles.first(where: { $0.id == id }) })
            ?? profiles.first(where: \.isDefault) ?? profiles.first else {
            throw LLMProviderError.invalidURL
        }
        // N1: Qwen-MT keys live in DashScopeStore, not ProviderKeyStore.
        // Reading the wrong store made every screen report missingAPIKey
        // as soon as Qwen-MT was picked as the main model.
        let stored: String?
        if profile.isQwenMT {
            stored = await DashScopeStore.loadKey()
        } else {
            stored = await ProviderKeyStore.loadKey(profileID: profile.id)
            // S13: one DeepSeek key covers both DeepSeek profiles —
            // a key saved under either id works for the other.
            if stored == nil, profile.isDeepSeek {
                let otherID = profile.id == RunseConstants.defaultProfileID
                    ? RunseConstants.deepSeekProProfileID
                    : RunseConstants.defaultProfileID
                stored = await ProviderKeyStore.loadKey(profileID: otherID)
            }
        }
        guard let stored else {
            throw LLMProviderError.missingAPIKey
        }
        let apiKey = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
        let template = templates.first { $0.action == .translate }
            ?? PromptTemplate.builtIns().first { $0.action == .translate }!
        return TranslationRequestContext(profile: profile, apiKey: apiKey, template: template)
    }
}
