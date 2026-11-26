import Foundation

public final class SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: RunseConstants.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    /// S16: `defaultTranslationLanguage` was removed — the setting
    /// had no reader (every translation passes its target
    /// explicitly), so it only pretended to do something.
    /// The model option picked in the model picker. Defaults to DeepSeek
    /// daily; the picker writes it and the translation screens read it.
    /// S13: "doubao-voice" was a selectable option until the picker
    /// stopped listing voice services as models — an old stored value
    /// migrates to DeepSeek daily on read.
    public var selectedModelOptionID: String {
        get {
            let raw = defaults.string(forKey: "selectedModelOptionID") ?? ModelCatalog.deepSeekFlashID
            return raw == "doubao-voice" ? ModelCatalog.deepSeekFlashID : raw
        }
        set { defaults.set(newValue, forKey: "selectedModelOptionID") }
    }

    public var hasSeenGetStartedGuide: Bool {
        get { defaults.bool(forKey: "hasSeenGetStartedGuide") }
        set { defaults.set(newValue, forKey: "hasSeenGetStartedGuide") }
    }

    /// Default translation tone (清单 4). The text screen can override
    /// it per translation; voice/photo use this stored value.
    public var translationTone: TranslationTone {
        get {
            guard let raw = defaults.string(forKey: "translationTone"),
                  let tone = TranslationTone(rawValue: raw) else { return .default }
            return tone
        }
        set { defaults.set(newValue.rawValue, forKey: "translationTone") }
    }

    /// Dual-model cross-check (清单 14). Off by default; the PDF
    /// screen switches it on per document when the document is a
    /// professional one.
    public var dualModelCheckEnabled: Bool {
        get { defaults.bool(forKey: "dualModelCheckEnabled") }
        set { defaults.set(newValue, forKey: "dualModelCheckEnabled") }
    }

    /// Item 5 (UI redesign): language-card toggles (Apple Translate style).
    /// 检测语言 defaults ON — auto mode has always detected the input
    /// language, so ON preserves current behavior.
    /// 播放翻译 defaults OFF — auto-reading after every text translation
    /// would burn TTS quota and surprise; the user opts in.
    /// 自动翻译 defaults OFF — translating on every pause burns API
    /// calls; the user opts in.
    public var playTranslation: Bool {
        get { defaults.bool(forKey: "playTranslation") }
        set { defaults.set(newValue, forKey: "playTranslation") }
    }

    public var autoTranslate: Bool {
        get { defaults.bool(forKey: "autoTranslate") }
        set { defaults.set(newValue, forKey: "autoTranslate") }
    }

    public var detectLanguage: Bool {
        get {
            guard defaults.object(forKey: "detectLanguage") != nil else { return true }
            return defaults.bool(forKey: "detectLanguage")
        }
        set { defaults.set(newValue, forKey: "detectLanguage") }
    }

    /// Item 11 (UI redesign): the conversation page's own language
    /// toggles — same three switches as the translate page's card,
    /// but a separate set of keys. The conversation defaults are ON:
    /// speaking is for translating, and a translation is for hearing
    /// (the page's established flow: speak → translate → speak).
    /// The translate page's three stay OFF by default (item 5 — a
    /// typed passage must not auto-translate on every pause or
    /// auto-read aloud unprompted). Each card controls its own page.
    public var conversationPlayTranslation: Bool {
        get {
            guard defaults.object(forKey: "conversationPlayTranslation") != nil else { return true }
            return defaults.bool(forKey: "conversationPlayTranslation")
        }
        set { defaults.set(newValue, forKey: "conversationPlayTranslation") }
    }

    public var conversationAutoTranslate: Bool {
        get {
            guard defaults.object(forKey: "conversationAutoTranslate") != nil else { return true }
            return defaults.bool(forKey: "conversationAutoTranslate")
        }
        set { defaults.set(newValue, forKey: "conversationAutoTranslate") }
    }

    public var conversationDetectLanguage: Bool {
        get {
            guard defaults.object(forKey: "conversationDetectLanguage") != nil else { return true }
            return defaults.bool(forKey: "conversationDetectLanguage")
        }
        set { defaults.set(newValue, forKey: "conversationDetectLanguage") }
    }
}
