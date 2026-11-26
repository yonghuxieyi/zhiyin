import Foundation
import SwiftData

public enum TransformAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case refine
    case translate
    case pinyin

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAIResponses
    case anthropicMessages
    case openAICompatible
    case anthropicCompatible

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        case .openAICompatible: "OpenAI Compatible"
        case .anthropicCompatible: "Anthropic Compatible"
        }
    }
}

public enum ProviderAPIStatus: String, Codable, Sendable {
    case untested
    case testing
    case passed
    case failed
}

public enum Tone: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, concise, polished, friendly, professional
    public var id: String { rawValue }
}

public enum Formality: String, Codable, CaseIterable, Identifiable, Sendable {
    case casual, neutral, formal
    public var id: String { rawValue }
}

public enum OutputLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case shorter, same, longer
    public var id: String { rawValue }
}

@Model public final class ProviderProfile {
    @Attribute(.unique) public var id: String
    public var name: String
    public var kindRawValue: String
    public var baseURL: String
    public var chatEndpoint: String
    public var model: String
    public var extraHeadersJSON: String
    public var isDefault: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var apiTestStatusRawValue: String = ProviderAPIStatus.untested.rawValue
    public var apiTestMessage: String?
    public var apiTestedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: ProviderKind,
        baseURL: String,
        chatEndpoint: String,
        model: String,
        extraHeadersJSON: String = "{}",
        isDefault: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kindRawValue = kind.rawValue
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
        self.model = model
        self.extraHeadersJSON = extraHeadersJSON
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: ProviderKind {
        get { ProviderKind(rawValue: kindRawValue) ?? .openAICompatible }
        set { kindRawValue = newValue.rawValue }
    }

    public var apiTestStatus: ProviderAPIStatus {
        get { ProviderAPIStatus(rawValue: apiTestStatusRawValue) ?? .untested }
        set { apiTestStatusRawValue = newValue.rawValue }
    }

    public static func defaultDeepSeek() -> ProviderProfile {
        ProviderProfile(
            id: RunseConstants.defaultProfileID,
            name: "DeepSeek",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            chatEndpoint: "/chat/completions",
            model: "deepseek-flash",
            isDefault: true
        )
    }

    /// Precision-flip preset for long-form translation. Not the default;
    /// seeded once by Bootstrap and left alone afterwards.
    public static func defaultDeepSeekPro() -> ProviderProfile {
        ProviderProfile(
            id: RunseConstants.deepSeekProProfileID,
            name: "DeepSeek Pro",
            kind: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            chatEndpoint: "/chat/completions",
            model: "deepseek-v4-pro",
            isDefault: false
        )
    }

    /// Qwen-MT Flash backup: used automatically when DeepSeek fails
    /// for a segment (requires a saved DashScope key). Seeded once by
    /// Bootstrap. Flash is the default backup; Plus is the higher
    /// quality, more natural variant. Which tone fits the user best
    /// is decided by a blind test once a DashScope key is available.
    public static func qwenMTFlash() -> ProviderProfile {
        ProviderProfile(
            id: QwenMT.flashProfileID,
            name: "Qwen-MT 备用",
            kind: .openAICompatible,
            baseURL: QwenMT.baseURL,
            chatEndpoint: "/chat/completions",
            model: QwenMT.flashModel,
            isDefault: false
        )
    }

    public static func qwenMTPlus() -> ProviderProfile {
        ProviderProfile(
            id: QwenMT.plusProfileID,
            name: "Qwen-MT Plus",
            kind: .openAICompatible,
            baseURL: QwenMT.baseURL,
            chatEndpoint: "/chat/completions",
            model: QwenMT.plusModel,
            isDefault: false
        )
    }

    public var isQwenMT: Bool {
        model.hasPrefix("qwen-mt")
    }

    /// S13: both DeepSeek profiles share one vendor key — a key saved
    /// under either profile id works for the other (the resolver
    /// falls back to the sibling id).
    public var isDeepSeek: Bool {
        id == RunseConstants.defaultProfileID || id == RunseConstants.deepSeekProProfileID
    }

    /// M3: Plus streams non-incrementally (each chunk is the full
    /// translation so far) while Flash is incremental. Only used to
    /// pick the chunk-merging strategy in `HTTPProviderClient`.
    public var isQwenMTPlus: Bool {
        model == QwenMT.plusModel
    }
}

@Model public final class PromptTemplate {
    @Attribute(.unique) public var id: String
    public var actionRawValue: String
    public var name: String
    public var systemTemplate: String
    public var userTemplate: String
    public var isBuiltIn: Bool
    public var updatedAt: Date

    public init(id: String, action: TransformAction, name: String, systemTemplate: String, userTemplate: String, isBuiltIn: Bool = true, updatedAt: Date = .now) {
        self.id = id
        self.actionRawValue = action.rawValue
        self.name = name
        self.systemTemplate = systemTemplate
        self.userTemplate = userTemplate
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
    }

    public var action: TransformAction {
        get { TransformAction(rawValue: actionRawValue) ?? .refine }
        set { actionRawValue = newValue.rawValue }
    }

    public static let defaultRefineID = "default-refine"
    public static let defaultTranslateID = "default-translate"
    public static let defaultPinyinID = "default-pinyin"

    public static func builtIns() -> [PromptTemplate] {
        [
            PromptTemplate(
                id: defaultRefineID,
                action: .refine,
                name: "Default Refine",
                systemTemplate: "You are a careful editor. Return only the revised text.",
                userTemplate: "Action: {{action}}\nTone: {{tone}}\nFormality: {{formality}}\nLength: {{length}}\nInstruction: {{custom_instruction}}\n\nPreserve the input language. Do not translate unless the instruction explicitly asks for translation.\n\nText:\n{{selected_text}}"
            ),
            PromptTemplate(
                id: defaultTranslateID,
                action: .translate,
                name: "Default Translate",
                systemTemplate: "You are a precise translator. Translate the whole passage with its full context — do not translate sentence by sentence in isolation. Keep terminology consistent throughout the passage. Match the requested register: formality {{formality}}, tone {{tone}}. Preserve meaning, formatting, and names. Return only the translation, no explanations.",
                userTemplate: "Translate the following text to {{target_language}}.\nFormality: {{formality}}\nTone: {{tone}}\nInstruction: {{custom_instruction}}\n\nText:\n{{selected_text}}"
            ),
            PromptTemplate(
                id: defaultPinyinID,
                action: .pinyin,
                name: "Default Pinyin",
                systemTemplate: "You convert Chinese text into Hanyu Pinyin. Output only the pinyin — no Chinese characters, no translation, no commentary. Use lowercase letters with tone marks placed on the correct vowel (ā á ǎ à, ē é ě è, ī í ǐ ì, ō ó ǒ ò, ū ú ǔ ù, ǖ ǘ ǚ ǜ). Neutral tone has no mark. Separate syllables within a word with no space; separate words with a single space. Preserve original punctuation and line breaks. Pass non-Chinese characters (Latin letters, digits, symbols) through unchanged. Disambiguate polyphonic characters (多音字) from context.",
                userTemplate: "Convert the following text to Hanyu Pinyin with correct tone marks.\nInstruction: {{custom_instruction}}\n\nText:\n{{selected_text}}"
            )
        ]
    }
}

@Model public final class TransformHistory {
    public var id: String
    public var providerID: String? = nil
    public var sourceExcerpt: String
    public var resultExcerpt: String
    public var providerName: String
    public var model: String
    public var actionRawValue: String
    public var targetLanguage: String?
    public var timestamp: Date
    public var status: String
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var totalTokens: Int = 0

    public init(
        id: String = UUID().uuidString,
        providerID: String? = nil,
        sourceExcerpt: String,
        resultExcerpt: String,
        providerName: String,
        model: String,
        action: TransformAction,
        targetLanguage: String?,
        timestamp: Date = .now,
        status: String,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.id = id
        self.providerID = providerID
        self.sourceExcerpt = sourceExcerpt
        self.resultExcerpt = resultExcerpt
        self.providerName = providerName
        self.model = model
        self.actionRawValue = action.rawValue
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.status = status
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// A saved sentence or term from a translation (清单 5): the user taps
/// "收藏" on a translated segment and can look it up later in the
/// 生词本. The schema is registered in Bootstrap.
@Model public final class VocabularyEntry {
    @Attribute(.unique) public var id: String
    public var sourceText: String
    public var translation: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceText: String,
        translation: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translation = translation
        self.createdAt = createdAt
    }
}
