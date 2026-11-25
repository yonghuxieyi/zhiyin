import Foundation
import Network

/// The model picker catalog. v1 ships the two DeepSeek cloud options;
/// the offline and overseas groups are placeholders so the picker shows
/// the full plan without letting the user pick something that is not
/// wired up yet.
public enum ModelGroup: String, CaseIterable, Identifiable, Sendable {
    case cloudChina
    case local
    case cloudOverseas
    case voice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cloudChina: "国内云端"
        case .local: "本地离线"
        case .cloudOverseas: "国外云端"
        case .voice: "语音"
        }
    }
}

public enum ModelOptionStatus: Sendable, Equatable {
    case available
    case comingSoon(String)
    case needsKey(String)
}

public struct ModelOption: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var detail: String
    public var group: ModelGroup
    /// SwiftData profile id for options backed by a provider profile.
    public var profileID: String?
    public var status: ModelOptionStatus

    public init(id: String, name: String, detail: String, group: ModelGroup, profileID: String? = nil, status: ModelOptionStatus) {
        self.id = id
        self.name = name
        self.detail = detail
        self.group = group
        self.profileID = profileID
        self.status = status
    }

    public var isSelectable: Bool {
        if case .available = status { return true }
        return false
    }

    public var statusText: String? {
        switch status {
        case .available: nil
        case .comingSoon(let note): note
        case .needsKey(let note): note
        }
    }
}

public enum ModelCatalog {
    public static let deepSeekFlashID = "deepseek-flash-1"
    public static let deepSeekProID = "deepseek-pro-1"

    /// All options, grouped. Voice availability is filled in by the UI
    /// from the keychain (configured or not); everything else is static.
    public static func options(voiceConfigured: Bool) -> [ModelOption] {
        [
            ModelOption(
                id: deepSeekFlashID,
                name: "DeepSeek 日常",
                detail: "deepseek-flash · 快、便宜，日常翻译",
                group: .cloudChina,
                profileID: RunseConstants.defaultProfileID,
                status: .available
            ),
            ModelOption(
                id: deepSeekProID,
                name: "DeepSeek Pro 精翻",
                detail: "deepseek-v4-pro · 长文、难句精翻",
                group: .cloudChina,
                profileID: RunseConstants.deepSeekProProfileID,
                status: .available
            ),
            ModelOption(
                id: "qwen-4b-offline",
                name: "Qwen 4B 离线",
                detail: "端侧大模型，断网也能翻",
                group: .local,
                status: .comingSoon("v1 之后接入")
            ),
            ModelOption(
                id: "claude-sonnet",
                name: "Claude Sonnet 5.5",
                detail: "国外云端旗舰，细腻度更高",
                group: .cloudOverseas,
                status: .needsKey("需要配置 Key，暂未接入")
            ),
            ModelOption(
                id: "gpt-sol",
                name: "GPT-6.1 Sol",
                detail: "国外云端，同价备选",
                group: .cloudOverseas,
                status: .needsKey("需要配置 Key，暂未接入")
            ),
            ModelOption(
                id: "doubao-voice",
                name: "豆包语音",
                detail: "火山豆包流式识别 + 合成",
                group: .voice,
                status: voiceConfigured ? .available : .needsKey("未配置 AppID 和 Access Token")
            )
        ]
    }

    public static func option(id: String, voiceConfigured: Bool) -> ModelOption? {
        options(voiceConfigured: voiceConfigured).first { $0.id == id }
    }
}

/// Tracks reachability so the picker can grey out the cloud groups when
/// the phone is offline.
@MainActor public final class ConnectivityMonitor: ObservableObject {
    @Published public private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: .global(qos: .background))
    }

    deinit {
        monitor.cancel()
    }
}
