import PDFKit
import RunseCore
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// PDF document translation (清单 11): import a PDF, extract text per
/// page (scanned pages are OCR'd with Vision), translate with the
/// glossary kept consistent, and export a translated PDF — text pages
/// keep their layout (translation replaces the original text in place),
/// scanned pages get the simplified layout. Progress is shown per page.
///
/// The dual-model cross-check (清单 14) is a per-document switch here:
/// off by default, on only for professional documents.
struct PDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]

    @State private var showingPicker = false
    @State private var document: PDFDocument?
    @State private var fileName = ""
    @State private var pages: [PDFPageContent] = []
    @State private var translated: [PDFTranslatedPage] = []
    @State private var isWorking = false
    @State private var progress = ""
    @State private var errorMessage: String?
    @State private var dualCheckNote: String?
    @State private var exportURL: URL?
    @State private var dualModelCheck = SettingsStore().dualModelCheckEnabled

    private let pipeline = TranslationPipeline()

    var body: some View {
        Form {
            Section("文档") {
                Button {
                    showingPicker = true
                } label: {
                    Label(document == nil ? "导入 PDF" : fileName, systemImage: "doc")
                }
                .disabled(isWorking)
                if !pages.isEmpty {
                    Text("\(pages.count) 页 · 其中 \(pages.filter(\.isScanned).count) 页是扫描版（走 OCR）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if document != nil {
                Section("校对") {
                    Toggle("双模型交叉校对（专业文档）", isOn: $dualModelCheck)
                        .onChange(of: dualModelCheck) { _, value in
                            SettingsStore().dualModelCheckEnabled = value
                        }
                    Text("平时默认关。打开后每段都由第二模型复核，分歧时按裁判规则选（术语命中优先）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let dualCheckNote {
                        Text(dualCheckNote)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Button {
                        Task { await runTranslation() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("翻译全文", systemImage: "globe")
                        }
                    }
                    .disabled(pages.isEmpty || isWorking)
                    Spacer()
                    if let exportURL {
                        ShareLink(item: exportURL, preview: SharePreview("翻译后的 PDF", image: Image(systemName: "doc"))) {
                            Label("导出 PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(.borderless)

                if isWorking {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if !translated.isEmpty {
                    Section("译文对照") {
                        ForEach(translated, id: \.index) { page in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(page.index + 1) 页" + (page.isScanned ? "（扫描版）" : ""))
                                    .font(.headline)
                                ForEach(Array(page.lines.enumerated()), id: \.offset) { _, line in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.source)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Text(line.translation)
                                            .font(.body)
                                        if let check = line.check, !check.agreed {
                                            Text(check.reason)
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("PDF 翻译")
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                Task { await loadDocument(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadDocument(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "读不到这个文件。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data) else {
                errorMessage = "这不是有效的 PDF。"
                return
            }
            self.document = document
            fileName = url.lastPathComponent
            translated = []
            exportURL = nil
            errorMessage = nil
            dualCheckNote = nil
            isWorking = true
            progress = "正在提取文字…"
            pages = await PDFTranslation.extractPages(from: document)
            isWorking = false
            progress = ""
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runTranslation() async {
        guard let document else { return }
        isWorking = true
        // M11: a long document takes a while — keep the screen awake
        // until translation finishes (or fails / is cancelled).
        UIApplication.shared.isIdleTimerDisabled = true
        errorMessage = nil
        dualCheckNote = nil
        exportURL = nil
        translated = []
        defer {
            isWorking = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
                throw LLMProviderError.invalidURL
            }
            let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
            let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
            guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
            let template = templates.first { $0.action == .translate }
                ?? PromptTemplate.builtIns().first { $0.action == .translate }!
            let target = TextLanguage.detect(pages.first?.plainText ?? "").translationTarget
            let tone = SettingsStore().translationTone
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            var totalPrompt = 0
            var totalCompletion = 0
            var didDualCheck = false
            var dualCheckAttempted = false
            var allTranslated: [PDFTranslatedPage] = []
            for page in pages {
                progress = "正在翻译第 \(page.index + 1) / \(pages.count) 页"
                var tlines: [PDFTranslatedLine] = []
                for line in page.lines {
                    let segments = TextSegmenter.segments(for: line.text, maxChars: TextSegmenter.maxChars(for: profile))
                    let results = try await pipeline.translate(
                        segments: segments,
                        profile: profile,
                        apiKey: apiKey,
                        targetLanguage: target,
                        template: template,
                        glossary: glossaryEntries,
                        tone: tone,
                        fallbackProfile: fallback?.profile,
                        fallbackAPIKey: fallback?.apiKey
                    ) { _, _ in }
                    totalPrompt += pipeline.lastUsage["prompt_tokens"] ?? 0
                    totalCompletion += pipeline.lastUsage["completion_tokens"] ?? 0
                    var translation = results.map(\.translation).joined(separator: "\n")
                    var check: DualModelCompare.Verdict?
                    if dualModelCheck, line.text.count >= 8 {
                        dualCheckAttempted = true
                        check = try? await DualModelChecker.check(
                            source: line.text,
                            primaryTranslation: translation,
                            primary: profile,
                            targetLanguage: target,
                            template: template,
                            glossary: glossaryEntries,
                            profiles: profiles,
                            tone: tone
                        )
                        if let check {
                            didDualCheck = true
                            translation = check.chosen
                        }
                    }
                    tlines.append(PDFTranslatedLine(source: line.text, translation: translation, bounds: line.bounds, check: check))
                }
                allTranslated.append(PDFTranslatedPage(index: page.index, lines: tlines, isScanned: page.isScanned, pageSize: page.pageSize))
                translated = allTranslated
            }
            if dualModelCheck, dualCheckAttempted, !didDualCheck {
                dualCheckNote = "双模型校对没生效：第二模型不可用（缺 Key 或调用失败），本次只用了主模型译文。"
            }
            progress = "正在生成 PDF…"
            if let data = PDFTranslation.exportPDF(original: document, translatedPages: allTranslated) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zhiyin-Translated.pdf")
                try data.write(to: url, options: .atomic)
                exportURL = url
            }
            progress = ""
            let firstSource = pages.first?.plainText ?? ""
            let firstResult = allTranslated.first?.plainTranslation ?? ""
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(firstSource),
                resultExcerpt: TextExcerpt.make(firstResult),
                providerName: profile.name,
                model: profile.model,
                action: .translate,
                targetLanguage: target,
                status: didDualCheck ? "success · 双模型校对" : (dualModelCheck && dualCheckAttempted ? "success · 双模型校对未生效" : "success"),
                promptTokens: totalPrompt,
                completionTokens: totalCompletion,
                totalTokens: totalPrompt + totalCompletion
            ))
            try? modelContext.save()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
