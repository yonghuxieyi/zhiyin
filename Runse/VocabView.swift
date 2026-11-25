import RunseCore
import SwiftData
import SwiftUI

/// 生词本 (清单 5): sentences and terms saved from translations.
/// Opened from Settings → 记录 → 生词本. Searchable, swipe to delete.
struct VocabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabularyEntry.createdAt, order: .reverse) private var items: [VocabularyEntry]
    @State private var searchText = ""

    private var filtered: [VocabularyEntry] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.sourceText.localizedCaseInsensitiveContains(searchText)
                || $0.translation.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "生词本还是空的",
                    systemImage: "bookmark",
                    description: Text("翻译页点译文旁的“收藏”，好句子和专业词就存到这里。")
                )
            }
            ForEach(filtered) { item in
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
                    modelContext.delete(filtered[offset])
                }
                try? modelContext.save()
            }
        }
        .navigationTitle("生词本")
        .searchable(text: $searchText, prompt: "搜索原文或译文")
    }
}
