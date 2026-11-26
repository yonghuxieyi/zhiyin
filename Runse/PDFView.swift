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
    @State private var documentHash: String?
    @State private var pages: [PDFPageContent] = []
    @State private var translated: [PDFTranslatedPage] = []
    @State private var isWorking = false
    @State private var progress = ""
    @State private var errorMessage: String?
    @State private var partialNote: String?
    @State private var resumeNote: String?
    @State private var dualCheckNote: String?
    @State private var exportURL: URL?
    @State private var translationTask: Task<Void, Never>?

    /// The dual-model switch reads/writes SettingsStore directly
    /// instead of a `@State` snapshot: the old snapshot was
    /// re-initialized (off) whenever the view was recreated, so
    /// importing a document reset the switch the user had just
    /// turned on.
    private var dualModelCheckBinding: Binding<Bool> {
        Binding(
            get: { SettingsStore().dualModelCheckEnabled },
            set: { SettingsStore().dualModelCheckEnabled = $0 }
        )
    }

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
                    Text("\(pages.count) 页 · 其中 \(pages.filter(\.isScanned).count) 页是扫描版（走 OCR）" + (pages.contains(where: \.ocrFailed) ? " · \(pages.filter(\.ocrFailed).count) 页 OCR 失败（文字没认出来）" : ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if document != nil {
                Section("校对") {
                    Toggle("双模型交叉校对（专业文档）", isOn: dualModelCheckBinding)
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
                        translationTask = Task { await runTranslation() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label(translated.isEmpty ? "翻译全文" : "继续翻译", systemImage: "globe")
                        }
                    }
                    .disabled(pages.isEmpty || isWorking)
                    if isWorking {
                        Button {
                            translationTask?.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                    }
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
                if let resumeNote {
                    Text(resumeNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let partialNote {
                    Text(partialNote)
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
                                ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { _, para in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(para.source)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Text(para.translation)
                                            .font(.body)
                                        if para.failed {
                                            Text("翻译失败，已保留原文，可点“继续翻译”重试。")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        } else if let check = para.check, !check.agreed {
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
            documentHash = PDFProgressStore.documentHash(data)
            translated = []
            exportURL = nil
            errorMessage = nil
            partialNote = nil
            resumeNote = nil
            dualCheckNote = nil
            isWorking = true
            progress = "正在提取文字…"
            pages = await PDFTranslation.extractPages(from: document)
            isWorking = false
            progress = ""
            // M12: resume from the breakpoint — if this document was
            // translated before (same data, same page count), restore
            // the finished pages so the user can continue instead of
            // starting over.
            if let hash = documentHash,
               let saved = PDFProgressStore.load(hash: hash, pageCount: pages.count),
               !saved.pages.isEmpty {
                translated = saved.pages.sorted { $0.index < $1.index }
                let done = translated.filter { $0.paragraphs.allSatisfy { !$0.failed } }.count
                resumeNote = "已恢复上次进度：\(done)/\(pages.count) 页已译完，可点“继续翻译”接着翻。"
                rebuildExport()
            }
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    /// Rebuilds the export file from the current `translated` pages
    /// (used after a resume, and after every finished page, so a
    /// partial result is always exportable — the M12 supplement: a
    /// failure used to leave finished pages visible but never
    /// exported or persisted).
    @MainActor
    private func rebuildExport() {
        guard let document, !translated.isEmpty else {
            exportURL = nil
            return
        }
        guard let data = PDFTranslation.exportPDF(original: document, translatedPages: translated) else {
            exportURL = nil
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zhiyin-Translated.pdf")
        if (try? data.write(to: url, options: .atomic)) != nil {
            exportURL = url
        }
    }

    @MainActor
    private func persistProgress() {
        guard let hash = documentHash else { return }
        try? PDFProgressStore.save(hash: hash, fileName: fileName, pageCount: pages.count, pages: translated)
    }

    @MainActor
    private func runTranslation() async {
        guard let document else { return }
        isWorking = true
        // M11: a long document takes a while — keep the screen awake
        // until translation finishes (or fails / is cancelled).
        UIApplication.shared.isIdleTimerDisabled = true
        errorMessage = nil
        partialNote = nil
        dualCheckNote = nil
        defer {
            isWorking = false
            translationTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
            let profile = request.profile
            let apiKey = request.apiKey
            let template = request.template
            // Direction from the majority language of the WHOLE book,
            // not just the first page: a cover or foreword in the
            // other language used to flip the entire document.
            let wholeBook = pages.map(\.plainText).joined(separator: "\n")
            let target = TextLanguage.detect(wholeBook).translationTarget
            let tone = SettingsStore().translationTone
            let dualModelCheck = SettingsStore().dualModelCheckEnabled
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            var totalPrompt = 0
            var totalCompletion = 0
            var didDualCheck = false
            var dualCheckAttempted = false
            var failedParagraphs = 0
            // Already-translated pages (from a resume) are reused;
            // only missing or failed paragraphs are translated.
            var allTranslated = Dictionary(uniqueKeysWithValues: translated.map { ($0.index, $0) })
            for page in pages {
                try Task.checkCancellation()
                let paragraphs = page.paragraphs
                if paragraphs.isEmpty {
                    // No text on this page (e.g. OCR found nothing):
                    // keep an empty translated page so export/persist
                    // stay aligned with the page list.
                    if allTranslated[page.index] == nil {
                        allTranslated[page.index] = PDFTranslatedPage(index: page.index, paragraphs: [], isScanned: page.isScanned, pageSize: page.pageSize)
                    }
                    continue
                }
                progress = "正在翻译第 \(page.index + 1) / \(pages.count) 页"
                let existing = allTranslated[page.index]?.paragraphs ?? []
                var tparas: [PDFTranslatedParagraph] = []
                for para in paragraphs {
                    try Task.checkCancellation()
                    // Reuse a finished paragraph from the resumed
                    // progress (matched by source text).
                    if let done = existing.first(where: { $0.source == para.text && !$0.failed }) {
                        tparas.append(done)
                        continue
                    }
                    // M12: one paragraph failing must not kill the
                    // whole run — keep the original text, mark it,
                    // and carry on.
                    do {
                        let segments = TextSegmenter.segments(for: para.text, maxChars: TextSegmenter.maxChars(for: profile))
                        let outcome = try await pipeline.translatePartial(
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
                        var translation = outcome.results.map(\.translation).joined(separator: "\n")
                        if outcome.failedSegmentIndex != nil {
                            // Part of the paragraph translated: keep
                            // what finished, mark the paragraph failed
                            // (cancellation is rethrown by the
                            // pipeline, so it never lands here).
                            failedParagraphs += 1
                            tparas.append(PDFTranslatedParagraph(
                                source: para.text,
                                translation: translation.isEmpty ? para.text : translation,
                                bounds: para.bounds, failed: true
                            ))
                            continue
                        }
                        var check: DualModelCompare.Verdict?
                        if dualModelCheck, para.text.count >= 8 {
                            dualCheckAttempted = true
                            check = try? await DualModelChecker.check(
                                source: para.text,
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
                        tparas.append(PDFTranslatedParagraph(source: para.text, translation: translation, bounds: para.bounds, check: check))
                    } catch {
                        // Cancellation is not a paragraph failure —
                        // let it stop the run (handled below).
                        if error is CancellationError { throw error }
                        failedParagraphs += 1
                        tparas.append(PDFTranslatedParagraph(source: para.text, translation: para.text, bounds: para.bounds, failed: true))
                    }
                }
                allTranslated[page.index] = PDFTranslatedPage(index: page.index, paragraphs: tparas, isScanned: page.isScanned, pageSize: page.pageSize)
                translated = allTranslated.keys.sorted().compactMap { allTranslated[$0] }
                // Persist after every page, so a crash or cancel
                // mid-run still leaves a resumable breakpoint.
                persistProgress()
                rebuildExport()
            }
            if dualModelCheck, dualCheckAttempted, !didDualCheck {
                dualCheckNote = "双模型校对没生效：第二模型不可用（缺 Key 或调用失败），本次只用了主模型译文。"
            }
            if failedParagraphs > 0 {
                partialNote = "\(failedParagraphs) 段翻译失败，已保留原文并可导出；点“继续翻译”可只重试失败的段落。"
            }
            if pipeline.lastFallbackUsed {
                let fallbackNote = "部分段落由 Qwen-MT 备用完成（主模型出错）。"
                partialNote = [partialNote, fallbackNote].compactMap { $0 }.joined(separator: " ")
            }
            progress = ""
            let firstSource = pages.first?.plainText ?? ""
            let firstResult = translated.first?.plainTranslation ?? ""
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(firstSource),
                resultExcerpt: TextExcerpt.make(firstResult),
                providerName: profile.name,
                model: profile.model,
                action: .translate,
                targetLanguage: target,
                status: failedParagraphs > 0
                    ? "partial · \(failedParagraphs) 段失败已保留原文"
                    : (didDualCheck ? "success · 双模型校对" : (dualModelCheck && dualCheckAttempted ? "success · 双模型校对未生效" : "success")),
                promptTokens: totalPrompt,
                completionTokens: totalCompletion,
                totalTokens: totalPrompt + totalCompletion
            ))
            try? modelContext.save()
        } catch {
            // Cancellation (the 取消 button) keeps the partial
            // result — it is not an error and not a failure to report.
            if error is CancellationError {
                progress = ""
                if !translated.isEmpty {
                    partialNote = "已取消，已译的部分已保存，可随时继续翻译。"
                }
                return
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // M12 supplement: even when the run dies on a setup error
            // (or mid-run), pages finished so far stay exported and
            // persisted instead of being visible-but-lost.
            persistProgress()
            rebuildExport()
        }
    }
}
