import Foundation

/// Doubao TTS 2.0 voices (resource `seed-tts-2.0`). All ids are from the
/// official voice list: only `_uranus_bigtts` voices work with
/// seed-tts-2.0 — 1.0 (moon/mars) voices come back "resource ID is
/// mismatched". The default (高冷御姐) was verified live 2026-11-25.
public struct DoubaoSpeaker: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var gender: Gender

    public enum Gender: String, Sendable {
        case female
        case male
    }

    public init(id: String, name: String, gender: Gender) {
        self.id = id
        self.name = name
        self.gender = gender
    }

    public static let all: [DoubaoSpeaker] = [
        DoubaoSpeaker(id: "zh_female_gaolengyujie_uranus_bigtts", name: "高冷御姐", gender: .female),
        DoubaoSpeaker(id: "zh_female_xiaohe_uranus_bigtts", name: "小何", gender: .female),
        DoubaoSpeaker(id: "zh_female_vv_uranus_bigtts", name: "Vivi", gender: .female),
        DoubaoSpeaker(id: "zh_female_shuangkuaisisi_uranus_bigtts", name: "爽快思思", gender: .female),
        DoubaoSpeaker(id: "zh_female_qingxinnvsheng_uranus_bigtts", name: "清新女声", gender: .female),
        DoubaoSpeaker(id: "zh_male_m191_uranus_bigtts", name: "云舟", gender: .male),
        DoubaoSpeaker(id: "zh_male_taocheng_uranus_bigtts", name: "小天", gender: .male),
        DoubaoSpeaker(id: "zh_male_yuanboxiaoshu_uranus_bigtts", name: "渊博小叔", gender: .male),
        DoubaoSpeaker(id: "zh_male_shenyeboke_uranus_bigtts", name: "深夜播客", gender: .male)
    ]

    public static let `default` = all[0]

    public static func named(_ id: String) -> DoubaoSpeaker? {
        all.first { $0.id == id }
    }
}

/// Voice preferences: which Doubao voice reads translations aloud and
/// how fast. Stored in the app-group UserDefaults (not the keychain:
/// these are preferences, not secrets).
public struct VoiceSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: RunseConstants.appGroupID) ?? .standard) {
        self.defaults = defaults
    }

    /// Selected Doubao speaker id. Falls back to the default voice when
    /// the stored id is unknown (e.g. after a voice list change).
    public var speakerID: String {
        get {
            let stored = defaults.string(forKey: "voiceSpeakerID") ?? DoubaoSpeaker.default.id
            return DoubaoSpeaker.named(stored) == nil ? DoubaoSpeaker.default.id : stored
        }
        set { defaults.set(newValue, forKey: "voiceSpeakerID") }
    }

    public var speaker: DoubaoSpeaker {
        DoubaoSpeaker.named(speakerID) ?? DoubaoSpeaker.default
    }

    /// Playback rate, 0.5x–2.0x. Default 1.0x.
    public var speechRate: Double {
        get {
            let stored = defaults.double(forKey: "voiceSpeechRate")
            guard stored != 0 else { return 1.0 }
            return min(2.0, max(0.5, stored))
        }
        set { defaults.set(min(2.0, max(0.5, newValue)), forKey: "voiceSpeechRate") }
    }

    /// "My voice": when true and a cloned voice exists, synthesis uses
    /// the user's cloned Qwen voice instead of the Doubao voices.
    public var useMyVoice: Bool {
        get { defaults.bool(forKey: "voiceUseMyVoice") }
        set { defaults.set(newValue, forKey: "voiceUseMyVoice") }
    }

    /// The V3 TTS `speech_rate` parameter is an int in [-50, 100]:
    /// 0 is normal speed, 100 is 2.0x, -50 is 0.5x (official docs).
    /// Pure function, covered by unit tests.
    public static func speechRateParam(for rate: Double) -> Int {
        let clamped = min(2.0, max(0.5, rate))
        return min(100, max(-50, Int(((clamped - 1.0) * 100).rounded())))
    }
}
