import Foundation

/// Plain-text export of translation history (清单 6): one block per
/// record, newest first. Pure function, covered by unit tests.
public enum HistoryExporter {
    public static func text(for items: [TransformHistory]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")

        let blocks = items.map { item in
            var lines: [String] = []
            lines.append("[\(formatter.string(from: item.timestamp))] \(item.actionRawValue.capitalized) · \(item.providerName) \(item.model)")
            lines.append("原文：\(item.sourceExcerpt)")
            lines.append("译文：\(item.resultExcerpt)")
            if item.totalTokens > 0 {
                lines.append("Token：\(item.totalTokens)（输入 \(item.promptTokens) / 输出 \(item.completionTokens)）")
            }
            return lines.joined(separator: "\n")
        }
        return blocks.joined(separator: "\n\n")
    }
}
