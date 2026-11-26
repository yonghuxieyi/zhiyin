import Foundation

/// DeepSeek spend display (清单 7): tokens used and estimated cost,
/// computed from the recorded history. Prices are the DeepSeek official
/// peak prices in CNY per 1M tokens (verified 2026-11-02); the UI labels
/// the result an estimate because off-peak runs are half price and
/// cache-hit input is cheaper.
///
/// F1: only DeepSeek rows are priced here. Qwen-MT fallback tokens are
/// recorded under their own model ("qwen-mt-flash") by the pipeline, so
/// they are excluded — pricing them at DeepSeek rates overstated the
/// spend. Qwen-MT runs on DashScope's free quota, so no cost is shown
/// for it; if it ever becomes paid, price it from its own rate card,
/// not this one.
public enum SpendCalculator {
    public static let flashInputYuanPerMillion: Double = 2
    public static let flashOutputYuanPerMillion: Double = 8
    public static let proInputYuanPerMillion: Double = 9
    public static let proOutputYuanPerMillion: Double = 27

    public struct Summary: Sendable, Equatable {
        public var requests: Int
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int
        public var costYuan: Double
    }

    public static func isDeepSeek(model: String) -> Bool {
        model.hasPrefix("deepseek")
    }

    /// Estimated cost for one call at peak prices.
    public static func costYuan(promptTokens: Int, completionTokens: Int, model: String) -> Double {
        let inputPrice: Double
        let outputPrice: Double
        if model.hasPrefix("deepseek-v4-pro") {
            inputPrice = proInputYuanPerMillion
            outputPrice = proOutputYuanPerMillion
        } else {
            inputPrice = flashInputYuanPerMillion
            outputPrice = flashOutputYuanPerMillion
        }
        return Double(promptTokens) / 1_000_000 * inputPrice
            + Double(completionTokens) / 1_000_000 * outputPrice
    }

    /// Totals over all recorded DeepSeek history rows.
    public static func summary(for items: [TransformHistory]) -> Summary {
        let deepseek = items.filter { isDeepSeek(model: $0.model) }
        let prompt = deepseek.reduce(0) { $0 + $1.promptTokens }
        let completion = deepseek.reduce(0) { $0 + $1.completionTokens }
        let cost = deepseek.reduce(0.0) {
            $0 + costYuan(promptTokens: $1.promptTokens, completionTokens: $1.completionTokens, model: $1.model)
        }
        return Summary(
            requests: deepseek.count,
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: prompt + completion,
            costYuan: cost
        )
    }
}
