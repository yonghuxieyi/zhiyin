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
    @Environment(\.dismiss) private var dismiss
    /// Item 13: the document page hides the floating pill nav
    /// (PillNavState) so the document gets the full
    /// screen; it comes back when this page goes away.
    @EnvironmentObject private var pillNavState: PillNavState
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
    @State private var loadTask: Task<Void, Never>?
    /// Item 13: leaving mid-translation asks stop or continue.
    @State private var showingLeavePrompt = false

    /// Item 13: document hashes with a translation run in flight.
    /// A run keeps going after its page is left (返回 → 继续翻译),
    /// so a re-entered page must not start a second run for the
    /// same document — the file-backed progress would interleave.
    /// @MainActor because every access is from @MainActor code.
    @MainActor private static var runningDocumentHashes: Set<String> = []

    /// Item 13: a run for this document is already going in the
    /// background (its page was left with 继续翻译).
    @MainActor
    private var isBackgroundTranslating: Bool {
        guard let hash = documentHash else { return false }
        return Self.runningDocumentHashes.contains(hash)
    }

    /// Item 13: rough token estimate for the whole document, so the
    /// user can judge the cost before starting. CJK ≈ 1.5
    /// tokens/char, other text ≈ 0.25 tokens/char — a labelled
    /// estimate, not a count.
    @MainActor
    private var estimatedTokens: Int {
        let text = pages.map(\.plainText).joined()
        var total = 0.0
        for scalar in text.unicodeScalars {
            total += scalar.properties.isIdeographic ? 1.5 : 0.25
        }
        return Int(total.rounded())
    }

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
            // Item 13 (22:39 point 5): the dual-model switch sits at
            // the top centre of the document page.
            if document != nil {
                Section {
                    HStack {
                        Spacer()
                        Text("双模型交叉校对")
                        Toggle("", isOn: dualModelCheckBinding)
                            .labelsHidden()
                        Spacer()
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
            }

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
                    .disabled(pages.isEmpty || isWorking || isBackgroundTranslating)
                    if isWorking {
                        Button {
                            translationTask?.cancel()
                            loadTask?.cancel()
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

                // Item 13: a background run is already translating
                // this document — show that instead of the estimate,
                // and keep the start button disabled above.
                if isBackgroundTranslating {
                    Text("后台还在翻译这篇文档，进度会自动保存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !pages.isEmpty {
                    Text("预计约 \(estimatedTokens) token（全文估算）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
        // Item 13 (22:39 point 1): a small back chevron at the
        // top-left instead of the system back button — tapping it
        // mid-translation asks stop or continue first.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    backTapped()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("返回")
            }
        }
        // Item 13 (22:39 point 1): the pill is gone on this page so
        // the document gets the full screen.
        .onAppear { pillNavState.isHidden = true }
        .onDisappear { pillNavState.isHidden = false }
        // Item 13 (22:39 point 4): leaving mid-translation asks
        // stop or continue. Continuing pops the page and the run
        // carries on in the background (screen off / locked included
        // — the run disables the idle timer and persists per page).
        .alert("正在翻译文档", isPresented: $showingLeavePrompt) {
            Button("停止翻译", role: .destructive) {
                stopAndLeave()
            }
            Button("继续翻译") {
                dismiss()
            }
        } message: {
            Text("离开后翻译会在后台继续，熄屏、锁屏都不会停，进度已保存，回来可以接着看。")
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                // S2: keep the handle so extraction can be cancelled
                // from the 取消 button (same button as translation).
                loadTask = Task { await loadDocument(url) }
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
            // S8: size guard before reading — a multi-hundred MB
            // scanned PDF must not be loaded whole into memory.
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64,
               size > PDFProgressStore.maxImportBytes {
                errorMessage = "这个 PDF 有 \(size / 1024 / 1024) MB，超过 200 MB 上限，手机上翻不动，请先拆小再导入。"
                return
            }
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data) else {
                errorMessage = "这不是有效的 PDF。"
                return
            }
            self.document = document
            fileName = url.lastPathComponent
            documentHash = (try? PDFProgressStore.documentHash(of: url)) ?? PDFProgressStore.documentHash(data)
            translated = []
            exportURL = nil
            errorMessage = nil
            partialNote = nil
            resumeNote = nil
            dualCheckNote = nil
            isWorking = true
            progress = "正在提取文字…"
            // S2: extraction is cancellable (per-page check inside);
            // a cancel leaves the document half-loaded, so clear the
            // partial pages instead of showing a torn document.
            do {
                pages = try await PDFTranslation.extractPages(from: document)
            } catch is CancellationError {
                pages = []
                self.document = nil
                fileName = ""
                documentHash = nil
                isWorking = false
                progress = ""
                return
            }
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
        // E4: the export must cover the whole document. After a
        // resume (or mid-run) `translated` only holds finished
        // pages — exporting just those silently dropped the rest, so
        // the user would share a file missing pages. Fill every
        // missing page with its source paragraphs (translation =
        // original text) so the exported file is page-complete; the
        // note below says which pages are still untranslated. This
        // synthesis is export-only: persistProgress still saves just
        // the finished pages.
        let byIndex = Dictionary(uniqueKeysWithValues: translated.map { ($0.index, $0) })
        var complete: [PDFTranslatedPage] = []
        var missing = 0
        for page in pages {
            if let done = byIndex[page.index] {
                complete.append(done)
            } else {
                missing += 1
                let paras = page.paragraphs.map {
                    PDFTranslatedParagraph(source: $0.text, translation: $0.text, bounds: $0.bounds)
                }
                complete.append(PDFTranslatedPage(index: page.index, paragraphs: paras, isScanned: page.isScanned, pageSize: page.pageSize))
            }
        }
        if missing > 0 {
            partialNote = "导出的 PDF 还有 \(missing) 页未翻译（保留原文），点“继续翻译”可补全。"
        }
        guard let data = PDFTranslation.exportPDF(original: document, translatedPages: complete) else {
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

    /// Item 13 (22:39 point 4): the back chevron. Not translating —
    /// leave at once. Translating — ask stop or continue. Still
    /// importing (no translation run yet) — cancel the import and
    /// leave: nothing is saved yet, so there is no background run
    /// to continue.
    @MainActor
    private func backTapped() {
        if translationTask != nil {
            showingLeavePrompt = true
        } else if isWorking {
            loadTask?.cancel()
            dismiss()
        } else {
            dismiss()
        }
    }

    /// Item 13: stop the run and leave the page.
    @MainActor
    private func stopAndLeave() {
        translationTask?.cancel()
        loadTask?.cancel()
        dismiss()
    }

    @MainActor
    private func runTranslation() async {
        guard let document else { return }
        // Item 13 (22:39 point 3): no usable translation service —
        // do not start. There is no balance API to query, so the
        // checkable precondition is a configured provider + key; a
        // 402 mid-run still surfaces as 余额不足 (LLMProviderError).
        let request: TranslationRequestContext
        do {
            request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
        } catch {
            errorMessage = "不能开始翻译：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            // The gate returned before the defer below was installed,
            // so clear the task handle here — otherwise backTapped
            // would think a run is still going.
            translationTask = nil
            return
        }
        // Item 13: a run for this document may already be going in
        // the background (left via 返回 → 继续翻译) — never run two.
        let runHash = documentHash
        if let runHash, Self.runningDocumentHashes.contains(runHash) {
            errorMessage = "这篇文档正在后台翻译，进度会自动保存，稍后再来接着看。"
            translationTask = nil
            return
        }
        if let runHash {
            Self.runningDocumentHashes.insert(runHash)
        }
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
            if let runHash {
                Self.runningDocumentHashes.remove(runHash)
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
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
            var totalUsageByModel: [String: (prompt: Int, completion: Int)] = [:]
            var didDualCheck = false
            var dualCheckAttempted = false
            var failedParagraphs = 0
            // S7: `pipeline.lastFallbackUsed` resets on every
            // translatePartial call, so it only ever reflects the
            // LAST segment — accumulate across the whole run.
            var didUseFallback = false
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
                        // F1: accumulate usage per model, not as one
                        // mixed total under the primary model.
                        for (model, usage) in pipeline.lastUsageByModel {
                            var entry = totalUsageByModel[model] ?? (0, 0)
                            entry.prompt += usage["prompt_tokens"] ?? 0
                            entry.completion += usage["completion_tokens"] ?? 0
                            totalUsageByModel[model] = entry
                        }
                        didUseFallback = didUseFallback || pipeline.lastFallbackUsed
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
                // S7: rebuilding the export from scratch after every
                // page is O(n²) — throttle to every 5th page; the
                // final rebuild below (and on cancel/error) covers
                // the tail.
                if page.index % 5 == 4 {
                    rebuildExport()
                }
            }
            rebuildExport()
            if dualModelCheck, dualCheckAttempted, !didDualCheck {
                dualCheckNote = "双模型校对没生效：第二模型不可用（缺 Key 或调用失败），本次只用了主模型译文。"
            }
            if failedParagraphs > 0 {
                partialNote = "\(failedParagraphs) 段翻译失败，已保留原文并可导出；点“继续翻译”可只重试失败的段落。"
            }
            if didUseFallback {
                let fallbackNote = "部分段落由 Qwen-MT 备用完成（主模型出错）。"
                partialNote = [partialNote, fallbackNote].compactMap { $0 }.joined(separator: " ")
            }
            progress = ""
            let firstSource = pages.first?.plainText ?? ""
            let firstResult = translated.first?.plainTranslation ?? ""
            // F1: one history row per model that actually translated —
            // booking the mixed total under the primary model priced
            // Qwen-MT fallback tokens at DeepSeek rates.
            let usageModels = totalUsageByModel.isEmpty ? [profile.model] : [profile.model] + totalUsageByModel.keys.filter { $0 != profile.model }.sorted()
            for model in usageModels {
                let totals = totalUsageByModel[model] ?? (0, 0)
                let isFallback = model != profile.model
                modelContext.insert(TransformHistory(
                    providerID: isFallback ? (fallback?.profile.id ?? profile.id) : profile.id,
                    sourceExcerpt: TextExcerpt.make(firstSource),
                    resultExcerpt: TextExcerpt.make(firstResult),
                    providerName: isFallback ? (fallback?.profile.name ?? profile.name) : profile.name,
                    model: model,
                    action: .translate,
                    targetLanguage: target,
                    status: failedParagraphs > 0
                        ? "partial · \(failedParagraphs) 段失败已保留原文"
                        : (didDualCheck ? "success · 双模型校对" : (dualModelCheck && dualCheckAttempted ? "success · 双模型校对未生效" : "success")),
                    promptTokens: totals.prompt,
                    completionTokens: totals.completion,
                    totalTokens: totals.prompt + totals.completion
                ))
            }
            try? modelContext.save()
        } catch {
            // Cancellation (the 取消 button) keeps the partial
            // result — it is not an error and not a failure to report.
            if error is CancellationError {
                progress = ""
                // S7: the export is throttled during the run, so a
                // cancel must rebuild once to cover the finished pages.
                rebuildExport()
                if !translated.isEmpty {
                    // E4: keep the untranslated-pages note visible —
                    // the export still contains those pages as
                    // original text.
                    let missingCount = pages.count - translated.count
                    partialNote = "已取消，已译的部分已保存，可随时继续翻译。" + (missingCount > 0 ? "导出的 PDF 还有 \(missingCount) 页未翻译（保留原文）。" : "")
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
