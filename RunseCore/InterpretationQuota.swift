import Foundation

/// Daily usage accounting for interpretation, shown on the
/// interpretation page so the user sees what the free allowances
/// cover and gets warned before overage. All figures are recorded
/// locally from the service's UsageResponse events and the local
/// ASR/TTS calls; nothing is queried from the console.
///
/// Allowances as of 2026-11-25 (console, unconfirmed where noted):
/// - 同声传译 2.0: 20 sessions/day (Ark console). The "~100 free
///   minutes/day" figure from research is NOT confirmed, so minutes
///   are tracked and shown but not treated as a limit.
/// - 流式识别 2.0 (trial): 20 hours total, to 2027-05-25.
/// - 语音合成 2.0 (trial): 20000 characters total, to 2027-05-25.
/// - Account balance: ¥2.36 (2026-11-25). Overage is pay-as-you-go,
///   so the page always shows the last known balance and its date.
public struct InterpretationQuotaStore: Sendable {
    public static let liveSessionsFreePerDay = 20
    public static let liveSessionsWarningAt = 16
    public static let asrTrialMinutesTotal: Double = 20 * 60
    public static let asrTrialWarningAt: Double = 16 * 60
    public static let ttsTrialCharsTotal = 20000
    public static let ttsTrialWarningAt = 16000

    private let defaults: UserDefaults
    private static let prefix = "zhiyin.interpret.quota."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public struct Snapshot: Sendable, Equatable {
        public var date: String
        public var liveSessionsToday: Int
        public var liveMinutesToday: Double
        public var inputAudioTokensToday: Double
        public var outputTextTokensToday: Double
        public var outputAudioTokensToday: Double
        public var asrMinutesTotal: Double
        public var ttsCharsTotal: Int
        public var balanceYuan: Double?
        public var balanceAsOf: Date?

        public var liveSessionsRemaining: Int {
            max(0, InterpretationQuotaStore.liveSessionsFreePerDay - liveSessionsToday)
        }

        public var liveSessionsWarning: Bool {
            liveSessionsToday >= InterpretationQuotaStore.liveSessionsWarningAt
        }

        public var asrWarning: Bool {
            asrMinutesTotal >= InterpretationQuotaStore.asrTrialWarningAt
        }

        public var ttsWarning: Bool {
            ttsCharsTotal >= InterpretationQuotaStore.ttsTrialWarningAt
        }

        public var asrMinutesRemaining: Double {
            max(0, InterpretationQuotaStore.asrTrialMinutesTotal - asrMinutesTotal)
        }

        public var ttsCharsRemaining: Int {
            max(0, InterpretationQuotaStore.ttsTrialCharsTotal - ttsCharsTotal)
        }
    }

    public func snapshot() -> Snapshot {
        let today = Self.todayKey()
        return Snapshot(
            date: today,
            liveSessionsToday: defaults.integer(forKey: Self.prefix + today + ".liveSessions"),
            liveMinutesToday: defaults.double(forKey: Self.prefix + today + ".liveMinutes"),
            inputAudioTokensToday: defaults.double(forKey: Self.prefix + today + ".inputAudioTokens"),
            outputTextTokensToday: defaults.double(forKey: Self.prefix + today + ".outputTextTokens"),
            outputAudioTokensToday: defaults.double(forKey: Self.prefix + today + ".outputAudioTokens"),
            asrMinutesTotal: defaults.double(forKey: Self.prefix + "asrMinutesTotal"),
            ttsCharsTotal: defaults.integer(forKey: Self.prefix + "ttsCharsTotal"),
            balanceYuan: defaults.object(forKey: Self.prefix + "balanceYuan") as? Double,
            balanceAsOf: defaults.object(forKey: Self.prefix + "balanceAsOf") as? Date
        )
    }

    /// Records one finished live session. `durationMsec` and token
    /// counts come from the UsageResponse billing event.
    public func recordLiveSession(durationMsec: Int64, inputAudioTokens: Double, outputTextTokens: Double, outputAudioTokens: Double) {
        let today = Self.todayKey()
        defaults.set(defaults.integer(forKey: Self.prefix + today + ".liveSessions") + 1, forKey: Self.prefix + today + ".liveSessions")
        defaults.set(defaults.double(forKey: Self.prefix + today + ".liveMinutes") + Double(durationMsec) / 60000.0, forKey: Self.prefix + today + ".liveMinutes")
        defaults.set(defaults.double(forKey: Self.prefix + today + ".inputAudioTokens") + inputAudioTokens, forKey: Self.prefix + today + ".inputAudioTokens")
        defaults.set(defaults.double(forKey: Self.prefix + today + ".outputTextTokens") + outputTextTokens, forKey: Self.prefix + today + ".outputTextTokens")
        defaults.set(defaults.double(forKey: Self.prefix + today + ".outputAudioTokens") + outputAudioTokens, forKey: Self.prefix + today + ".outputAudioTokens")
    }

    public func recordASR(minutes: Double) {
        defaults.set(defaults.double(forKey: Self.prefix + "asrMinutesTotal") + minutes, forKey: Self.prefix + "asrMinutesTotal")
    }

    public func recordTTS(chars: Int) {
        defaults.set(defaults.integer(forKey: Self.prefix + "ttsCharsTotal") + chars, forKey: Self.prefix + "ttsCharsTotal")
    }

    public func setBalance(_ yuan: Double, asOf date: Date = .now) {
        defaults.set(yuan, forKey: Self.prefix + "balanceYuan")
        defaults.set(date, forKey: Self.prefix + "balanceAsOf")
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
