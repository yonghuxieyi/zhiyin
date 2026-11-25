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
        defer { isTranslating = false }
        do {
            guard let profile = selectedProfile() else { throw LLMProviderError.invalidURL }
            let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
            let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
            guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
            let template = templates.first { $0.action == .translate }
                ?? PromptTemplate.builtIns().first { $0.action == .translate }!
            let parts = TextSegmenter.segments(for: inputText)
            segments = parts.map { SegmentRow(source: $0) }
            if extractedCandidates.isEmpty { extractTerms() }
            let glossary = useGlossary ? glossaryEntries : []
            let results = try await pipeline.translate(
                segments: parts,
                profile: profile,
                apiKey: apiKey,
                targetLanguage: targetLanguage,
                template: template,
                glossary: glossary
            ) { index, partial in
                segments[index].translation = partial
                segments[index].isTranslating = true
            }
            for (index, result) in results.enumerated() {
                segments[index].translation = result.translation
                segments[index].isTranslating = false
                segments[index].isDone = true
            }
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(inputText),
                resultExcerpt: TextExcerpt.make(results.map(\.translation).joined(separator: "\n")),
                providerName: profile.name,
                model: profile.model,
                action: .translate,
                targetLanguage: targetLanguage,
                status: "success"
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
