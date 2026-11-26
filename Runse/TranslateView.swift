import RunseCore
import SwiftData
import SwiftUI
import UIKit

/// Long-text translation: paste or type a long passage, it is split into
/// segments, translated one by one with progress, and shown side by side
/// with the source. A glossary keeps repeated terms consistent.
struct TranslateView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]
    @Query(sort: \VocabularyEntry.createdAt, order: .reverse) private var vocabEntries: [VocabularyEntry]

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var direction: TranslationDirection = .auto
    @State private var segments: [SegmentRow] = []
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var didCopy = false
    @State private var useGlossary = true
    @State private var showingGlossary = false
    @State private var extractedCandidates: [(term: String, count: Int)] = []
    @State private var tone = SettingsStore().translationTone
    @State private var fallbackUsed = false
    @State private var savedVocabIDs: Set<UUID> = []

    private let settings = SettingsStore()
    private let pipeline = TranslationPipeline()

    var body: some View {
        NavigationStack {
            Form {
                Section("原文") {
                    TextEditor(text: $inputText)
                        .frame(minHeight: 120)
                        .focused($inputFocused)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Button("Select All") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                }
                                .disabled(!inputFocused || inputText.isEmpty)
                                Spacer()
                                Button("Done") { inputFocused = false }
                            }
                        }
                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            inputText = clipboard
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasStrings)
                }

                Section("方向") {
                    Picker("翻译方向", selection: $direction) {
                        ForEach(TranslationDirection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("自动：中文翻英文，英文翻中文。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("语气") {
                    Picker("语气", selection: $tone) {
                        ForEach(TranslationTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: tone) { _, value in
                        settings.translationTone = value
                    }
                }

                Section("术语表") {
                    Toggle("翻译时应用术语表", isOn: $useGlossary)
                    Button("提取术语") {
                        extractTerms()
                        showingGlossary = true
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !glossaryEntries.isEmpty {
                        Text("\(glossaryEntries.count) 个术语，其中 \(glossaryEntries.filter { !$0.targetTranslation.isEmpty }.count) 个已填译法")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("文档") {
                    NavigationLink("翻译 PDF 文档") {
                        PDFView()
                    }
                    Text("导入 PDF，按页翻译，导出保留排版的译文 PDF。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await runTranslation() }
                    } label: {
                        if isTranslating {
                            ProgressView()
                        } else {
                            Label("翻译", systemImage: "globe")
                        }
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranslating)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = segments.map(\.translation).joined(separator: "\n")
                        didCopy = true
                    } label: {
                        Label(LocalizedStringKey(didCopy ? "Copied" : "Copy"), systemImage: "doc.on.doc")
                    }
                    .disabled(segments.isEmpty || isTranslating)
                }
                .buttonStyle(.borderless)

                if isTranslating {
                    let done = segments.filter { $0.isDone }.count
                    ProgressView("正在翻译第 \(min(done + 1, max(segments.count, 1))) / \(max(segments.count, 1)) 段")
                }

                if fallbackUsed {
                    Text("部分段落由 Qwen-MT 备用完成（DeepSeek 出错）。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if !segments.isEmpty {
                    Section("译文（原文对照）") {
                        ForEach(segments) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row.source)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if row.translation.isEmpty {
                                    if row.isTranslating {
                                        ProgressView()
                                    } else {
                                        Text("等待翻译")
                                            .font(.callout)
                                            .foregroundStyle(.tertiary)
                                    }
                                } else {
                                    Text(row.translation)
                                        .font(.body)
                                    Button {
                                        // Same sentence re-translated gets a new row id;
                                        // don't insert a duplicate entry for it.
                                        if !vocabEntries.contains(where: { $0.sourceText == row.source && $0.translation == row.translation }) {
                                            modelContext.insert(VocabularyEntry(sourceText: row.source, translation: row.translation))
                                            try? modelContext.save()
                                        }
                                        savedVocabIDs.insert(row.id)
                                    } label: {
                                        Label(savedVocabIDs.contains(row.id) ? "已收藏" : "收藏", systemImage: savedVocabIDs.contains(row.id) ? "bookmark.fill" : "bookmark")
                                    }
                                    .font(.caption)
                                    .disabled(savedVocabIDs.contains(row.id))
                                }
                                if let error = row.error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("翻译")
            .sheet(isPresented: $showingGlossary) {
                GlossaryEditorView(candidates: extractedCandidates)
            }
            .onChange(of: inputText) { _, _ in didCopy = false }
        }
    }

    private var targetLanguage: String {
        switch direction {
        case .auto:
            TextLanguage.detect(inputText).translationTarget
        case .toEnglish:
            "English"
        case .toChinese:
            "中文"
        }
    }

    private func extractTerms() {
        extractedCandidates = GlossaryExtractor.candidates(from: inputText)
        for candidate in extractedCandidates where !glossaryEntries.contains(where: { $0.sourceTerm == candidate.term }) {
            modelContext.insert(GlossaryEntry(sourceTerm: candidate.term))
        }
        try? modelContext.save()
    }

    @MainActor
    private func runTranslation() async {
        isTranslating = true
        errorMessage = nil
        didCopy = false
        fallbackUsed = false
        savedVocabIDs = []
        defer { isTranslating = false }
        do {
            let request = try await TranslationRequestResolver.resolve(
                profiles: profiles, templates: templates,
                profileID: selectedProfile()?.id
            )
            let profile = request.profile
            let apiKey = request.apiKey
            let template = request.template
            let parts = TextSegmenter.segments(for: inputText, maxChars: TextSegmenter.maxChars(for: profile))
            segments = parts.map { SegmentRow(source: $0) }
            if extractedCandidates.isEmpty { extractTerms() }
            let glossary = useGlossary ? glossaryEntries : []
            // Qwen-MT backup: only when the primary is not Qwen-MT itself.
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            // Partial outcome: a failed segment stops the run but the
            // finished segments stay on screen, and the failed one is
            // marked instead of the whole run being thrown away.
            let outcome = try await pipeline.translatePartial(
                segments: parts,
                profile: profile,
                apiKey: apiKey,
                targetLanguage: targetLanguage,
                template: template,
                glossary: glossary,
                tone: tone,
                fallbackProfile: fallback?.profile,
                fallbackAPIKey: fallback?.apiKey
            ) { index, partial in
                segments[index].translation = partial
                segments[index].isTranslating = true
            }
            let results = outcome.results
            for (index, result) in results.enumerated() {
                segments[index].translation = result.translation
                segments[index].isTranslating = false
                segments[index].isDone = true
            }
            if let failedIndex = outcome.failedSegmentIndex, let error = outcome.error {
                segments[failedIndex].isTranslating = false
                segments[failedIndex].error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            fallbackUsed = pipeline.lastFallbackUsed
            let usage = pipeline.lastUsage
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(inputText),
                resultExcerpt: TextExcerpt.make(results.map(\.translation).joined(separator: "\n")),
                providerName: profile.name,
                model: profile.model,
                action: .translate,
                targetLanguage: targetLanguage,
                status: outcome.isComplete
                    ? (pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success")
                    : "partial · 第 \(outcome.failedSegmentIndex! + 1) 段失败",
                promptTokens: usage["prompt_tokens"] ?? 0,
                completionTokens: usage["completion_tokens"] ?? 0,
                totalTokens: usage["total_tokens"] ?? 0
            ))
            try? modelContext.save()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func selectedProfile() -> ProviderProfile? {
        let optionID = settings.selectedModelOptionID
        if let option = ModelCatalog.option(id: optionID, voiceConfigured: false),
           let profileID = option.profileID,
           let profile = profiles.first(where: { $0.id == profileID }) {
            return profile
        }
        return profiles.first(where: \.isDefault) ?? profiles.first
    }
}

enum TranslationDirection: String, CaseIterable, Identifiable {
    case auto, toEnglish, toChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "自动"
        case .toEnglish: "翻成英文"
        case .toChinese: "翻成中文"
        }
    }
}

struct SegmentRow: Identifiable {
    let id = UUID()
    var source: String
    var translation = ""
    var isTranslating = false
    var isDone = false
    var error: String?
}

/// Glossary editor: extracted terms with editable translations.
struct GlossaryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GlossaryEntry.sourceTerm) private var entries: [GlossaryEntry]
    let candidates: [(term: String, count: Int)]

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView("没有术语", systemImage: "book", description: Text("先在原文里提取术语，重复出现的词会列在这里。"))
                }
                ForEach(entries) { entry in
                    GlossaryRowView(entry: entry)
                }
                .onDelete { offsets in
                    for offset in offsets {
                        modelContext.delete(entries[offset])
                    }
                    try? modelContext.save()
                }
            }
            .navigationTitle("术语表")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct GlossaryRowView: View {
    @Bindable var entry: GlossaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.sourceTerm)
                .font(.headline)
            TextField("译法（空着由模型决定）", text: $entry.targetTranslation)
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 4)
    }
}
