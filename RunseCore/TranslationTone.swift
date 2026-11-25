import Foundation

/// Translation tone modes (清单 4): a register switch appended to the
/// translation system prompt. The default mode adds nothing — the
/// model translates in its neutral register.
public enum TranslationTone: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case formal
    case colloquial
    case polite
    case business

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .default: "默认"
        case .formal: "正式"
        case .colloquial: "口语"
        case .polite: "礼貌"
        case .business: "商务"
        }
    }

    /// Instruction appended to the translation system prompt. Empty
    /// for the default mode.
    public var instruction: String {
        switch self {
        case .default:
            ""
        case .formal:
            "Use a formal, written register: complete sentences, no slang, respectful and precise wording."
        case .colloquial:
            "Use natural, conversational, spoken-style language: relaxed, everyday wording as people actually talk."
        case .polite:
            "Use polite, courteous phrasing: softeners and respectful forms where natural, never blunt."
        case .business:
            "Use concise business-professional language: clear, direct, and appropriate for workplace communication."
        }
    }
}
