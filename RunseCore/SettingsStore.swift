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

    public var hasSeenGetStartedGuide: Bool {
        get { defaults.bool(forKey: "hasSeenGetStartedGuide") }
        set { defaults.set(newValue, forKey: "hasSeenGetStartedGuide") }
    }
}
