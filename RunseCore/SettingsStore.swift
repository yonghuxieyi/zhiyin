import Foundation

public final class SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: RunseConstants.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    public var defaultTranslationLanguage: String {
        get { defaults.string(forKey: "defaultTranslationLanguage") ?? RunseConstants.defaultTranslationLanguage }
        set { defaults.set(newValue, forKey: "defaultTranslationLanguage") }
    }

    /// The model option picked in the model picker. Defaults to DeepSeek
    /// daily; the picker writes it and the translation screens read it.
    public var selectedModelOptionID: String {
        get { defaults.string(forKey: "selectedModelOptionID") ?? ModelCatalog.deepSeekFlashID }
        set { defaults.set(newValue, forKey: "selectedModelOptionID") }
    }

    public var hasSeenGetStartedGuide: Bool {
        get { defaults.bool(forKey: "hasSeenGetStartedGuide") }
        set { defaults.set(newValue, forKey: "hasSeenGetStartedGuide") }
    }
}
