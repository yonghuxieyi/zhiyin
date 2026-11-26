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
}
