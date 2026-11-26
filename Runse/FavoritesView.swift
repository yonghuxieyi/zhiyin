import RunseCore
import SwiftData
import SwiftUI

/// Item 4 (UI redesign): Apple "个人收藏" style — 生词本 on top,
/// 最近项目 (history) below, one search box for both, no export.
/// Opened from the top-left list icon on the translate page.
/// (HistoryView and VocabView stay for Settings → 记录.)
struct FavoritesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyEntry.createdAt, order: .reverse) private var vocab: [VocabularyEntry]
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var history: [TransformHistory]
    @State private var searchText = ""

    private var filteredVocab: [VocabularyEntry] {
        guard !searchText.isEmpty else { return vocab }
        return vocab.filter {
            $0.sourceText.localizedCaseInsensitiveContains(searchText)
                || $0.translation.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredHistory: [TransformHistory] {
        guard !searchText.isEmpty else { return history }
        return history.filter {
            $0.sourceExcerpt.localizedCaseInsensitiveContains(searchText)
                || $0.resultExcerpt.localizedCaseInsensitiveContains(searchText)
                || $0.providerName.localizedCaseInsensitiveContains(searchText)
                || $0.model.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if filteredVocab.isEmpty && filteredHistory.isEmpty {
                ContentUnavailableView(
                    "没有匹配的结果",
                    systemImage: "magnifyingglass",
                    description: Text(searchText.isEmpty ? "收藏的句子和翻过的内容会记在这里。" : "没有匹配 “\(searchText)” 的内容。")
                )
            }

            Section("个人收藏") {
                if filteredVocab.isEmpty {
                    Text(searchText.isEmpty ? "生词本还是空的" : "没有匹配的收藏")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredVocab) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.sourceText)
                            .font(.body)
                        Text(item.translation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        modelContext.delete(filteredVocab[offset])
                    }
                    try? modelContext.save()
                }
            }

            Section("最近项目") {
                if filteredHistory.isEmpty {
                    Text(searchText.isEmpty ? "没有历史记录" : "没有匹配的历史")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredHistory) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.resultExcerpt)
                            .font(.body)
                        HStack(spacing: 0) {
                            Text(LocalizedStringKey(item.actionRawValue.capitalized))
                            Text(" · \(item.providerName) · \(item.model)")
                            if item.totalTokens > 0 {
                                Text(" · \(item.totalTokens) token")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        modelContext.delete(filteredHistory[offset])
                    }
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle("个人收藏")
        .searchable(text: $searchText, prompt: "搜索原文、译文或模型")
    }
}
