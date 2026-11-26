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
    // S24: stored handle for the run — the 取消 button cancels it
    // (translatePartial rethrows CancellationError, so the run
    // actually stops; finished segments stay on screen).
    @State private var translationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var didCopy = false
    @State private var useGlossary = true
    @State private var showingGlossary = false
    @State private var extractedCandidates: [(term: String, count: Int)] = []
    @State private var tone = SettingsStore().translationTone
    @State private var fallbackUsed = false
    @State private var savedVocabIDs: Set<UUID> = []
    @State private var showingFavorites = false
    @State private var showingSettings = false
    @State private var showingModelPicker = false
    @State private var showingFullscreen = false

    private let settings = SettingsStore()
    private let pipeline = TranslationPipeline()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    docEntry
                    languageCard
                    inputCard

                    HStack {
                        Button {
                            translationTask = Task { await runTranslation() }
                        } label: {
                            if isTranslating {
                                ProgressView()
                            } else {
                                Label("翻译", systemImage: "globe")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranslating)

                        if isTranslating {
                            Button {
                                translationTask?.cancel()
                            } label: {
                                Label("取消", systemImage: "xmark.circle")
                            }
                        }

                        Spacer()

                        if isTranslating {
                            let done = segments.filter { $0.isDone }.count
                            Text("正在翻译第 \(min(done + 1, max(segments.count, 1))) / \(max(segments.count, 1)) 段")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if fallbackUsed {
                        Text("部分段落由 Qwen-MT 备用完成（DeepSeek 出错）。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !segments.isEmpty || isTranslating {
                        resultCard
                    }

                    toneRow
                    glossaryRow
                }
                .padding()
            }
            .navigationTitle("翻译")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingFavorites = true
                    } label: {
                        Label("收藏与历史", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingSettings = true } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        Button { showingModelPicker = true } label: {
                            Label("选择模型", systemImage: "cpu")
                        }
                        Button { showingGlossary = true } label: {
                            Label("术语表", systemImage: "book")
                        }
                        Button(role: .destructive) { nextTranslation() } label: {
                            Label("清空", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                // Item 3: the checkmark only shows once text has been entered.
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { inputFocused = false } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel("完成")
                    }
                }
            }
            .sheet(isPresented: $showingGlossary) {
                GlossaryEditorView(candidates: extractedCandidates)
            }
            .sheet(isPresented: $showingFavorites) {
                NavigationStack { HistoryView() }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet()
            }
            .fullScreenCover(isPresented: $showingFullscreen) {
                NavigationStack {
                    ScrollView {
                        Text(segments.map(\.translation).joined(separator: "\n"))
                            .font(.title2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("译文")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingFullscreen = false }
                        }
                    }
                }
            }
            .task {
                voiceConfig = await VolcanoVoiceStore.load()
            }
            .onDisappear {
                // N6: leaving the page must stop the mic / playback.
                if isDictating {
                    Task { await stopDictation() }
                }
                if isSpeaking {
                    speakTask?.cancel()
                    speakTask = nil
                    playbackPollTask?.cancel()
                    playbackPollTask = nil
                    isSpeaking = false
                    player.stop()
                }
            }
            .onChange(of: inputText) { _, _ in didCopy = false }
        }
    }

    /// Item 2 (UI redesign): Apple-style language card — source on top,
    /// target below, swap button on the right.
    private var languageCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Menu {
                    Button("中文（普通话，简体）") { setSourceLanguage(.chinese) }
                    Button("英语（美国）") { setSourceLanguage(.english) }
                } label: {
                    HStack {
                        Text(languageDisplayName(currentPair.source))
                            .font(.body)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .padding(.vertical, 12)

                Divider()

                Menu {
                    Button("中文（普通话，简体）") { setTargetLanguage(.chinese) }
                    Button("英语（美国）") { setTargetLanguage(.english) }
                } label: {
                    HStack {
                        Text(languageDisplayName(currentPair.target))
                            .font(.body)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .padding(.vertical, 12)
            }

            Button {
                swapDirection()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("互换语种")
        }
        .padding(.horizontal)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Item 2: input card — source language label, paste button,
    /// TextEditor with placeholder, dictation mic at the bottom right.
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(languageDisplayName(currentPair.source))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    if let clipboard = UIPasteboard.general.string {
                        inputText = clipboard
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .disabled(!UIPasteboard.general.hasStrings)
            }
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("输入文字")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $inputText)
                    .frame(minHeight: 120, maxHeight: 320)
                    .focused($inputFocused)
                    .scrollContentBackground(.hidden)
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
            }
            HStack {
                if isDictating {
                    Text("正在听写…")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: isDictating ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(isDictating ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDictating ? "停止听写" : "语音输入")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Item 2: result card — target language label, read-aloud button,
    /// segment list, and the bottom action row: fullscreen, star,
    /// copy, and 下一个.
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(languageDisplayName(currentPair.target))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    toggleSpeak()
                } label: {
                    Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(segments.allSatisfy { $0.translation.isEmpty })
                .accessibilityLabel(isSpeaking ? "停止朗读" : "朗读译文")
            }

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

            Divider()

            HStack(spacing: 24) {
                Button { showingFullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("全屏")
                .disabled(segments.allSatisfy { $0.translation.isEmpty })
                Button { favoriteAll() } label: {
                    Image(systemName: allSegmentsSaved ? "star.fill" : "star")
                        .foregroundStyle(allSegmentsSaved ? .yellow : .primary)
                }
                .accessibilityLabel("收藏译文")
                .disabled(segments.allSatisfy { $0.translation.isEmpty })
                Button {
                    UIPasteboard.general.string = segments.map(\.translation).joined(separator: "\n")
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(didCopy ? "已复制" : "复制译文")
                .disabled(segments.isEmpty || isTranslating)
                Spacer()
                Button("下一个") { nextTranslation() }
                    .buttonStyle(.borderless)
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Tone stays on the translate page as a compact row — the settings
    /// page (item 14) also carries it, but the translate page is where
    /// it is used every time.
    private var toneRow: some View {
        HStack {
            Text("语气")
                .font(.subheadline)
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
    }

    private var glossaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("翻译时应用术语表", isOn: $useGlossary)
            HStack {
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
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Item 3 (UI redesign): document entry at the top center of the
    /// home page — just the two characters 文档 with an icon.
    private var docEntry: some View {
        NavigationLink {
            PDFView()
        } label: {
            Label("文档", systemImage: "doc.text")
                .font(.headline)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
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

    /// Item 2: the language pair shown on the card. An explicit
    /// direction wins; in auto mode the detected language of the
    /// input decides (empty input defaults to 中文 → 英语).
    private var currentPair: (source: TextLanguage, target: TextLanguage) {
        switch direction {
        case .toEnglish:
            // Bare tuple literals don't get the function's return type as
            // contextual type in an implicit switch-branch return, so the
            // enum cases must be fully qualified here.
            return (source: TextLanguage.chinese, target: TextLanguage.english)
        case .toChinese:
            return (source: TextLanguage.english, target: TextLanguage.chinese)
        case .auto:
            guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (.chinese, .english)
            }
            let detected = TextLanguage.detect(inputText)
            return (detected, detected == .chinese ? .english : .chinese)
        }
    }

    private func languageDisplayName(_ language: TextLanguage) -> String {
        switch language {
        case .chinese: "中文（普通话，简体）"
        case .english: "英语（美国）"
        }
    }

    private func setSourceLanguage(_ language: TextLanguage) {
        direction = language == .chinese ? .toEnglish : .toChinese
    }

    private func setTargetLanguage(_ language: TextLanguage) {
        direction = language == .english ? .toEnglish : .toChinese
    }

    private func swapDirection() {
        direction = currentPair.source == .chinese ? .toChinese : .toEnglish
    }

    private var allSegmentsSaved: Bool {
        !segments.isEmpty && segments.filter { !$0.translation.isEmpty }.allSatisfy { row in
            vocabEntries.contains { $0.sourceText == row.source && $0.translation == row.translation }
        }
    }

    private func favoriteAll() {
        for row in segments where !row.translation.isEmpty {
            if !vocabEntries.contains(where: { $0.sourceText == row.source && $0.translation == row.translation }) {
                modelContext.insert(VocabularyEntry(sourceText: row.source, translation: row.translation))
            }
        }
        try? modelContext.save()
        savedVocabIDs.formUnion(segments.map(\.id))
    }

    /// "下一个": clear everything and focus the input for the next passage.
    private func nextTranslation() {
        inputText = ""
        segments = []
        errorMessage = nil
        didCopy = false
        fallbackUsed = false
        savedVocabIDs = []
        inputFocused = true
    }

    // MARK: - Inline dictation (input mic)

    private let recorder = VoiceRecorder()
    private let player = AudioPlayer()
    @State private var voiceConfig: VolcanoVoiceConfig?
    @State private var isDictating = false
    @State private var asrClient: VolcanoASRClient?
    @State private var dictationTask: Task<Void, Never>?
    @State private var audioFeedTask: Task<Void, Never>?
    @State private var dictationBaseText = ""

    @MainActor
    private func toggleDictation() {
        if isDictating {
            Task { await stopDictation() }
        } else {
            Task { await startDictation() }
        }
    }

    @MainActor
    private func startDictation() async {
        guard let config = voiceConfig else {
            errorMessage = "语音未配置：去设置里填火山豆包的 AppID 和 Access Token。"
            return
        }
        errorMessage = nil
        do {
            // N7: check the mic before opening the ASR session — a
            // denied mic must not burn a billable ASR start first.
            try await VoiceRecorder.requireMicrophonePermission()
            let client = VolcanoASRClient(config: config)
            asrClient = client
            dictationBaseText = inputText
            isDictating = true
            let stream = try await client.start()
            dictationTask = Task {
                for await (text, _) in stream {
                    let base = dictationBaseText
                    let separator = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
                    inputText = base + separator + text
                }
            }
            let audioStream = try await recorder.start()
            audioFeedTask = Task {
                for await chunk in audioStream {
                    try? await client.sendAudio(chunk)
                }
            }
        } catch {
            dictationTask?.cancel()
            dictationTask = nil
            audioFeedTask?.cancel()
            audioFeedTask = nil
            await asrClient?.cancel()
            asrClient = nil
            isDictating = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func stopDictation() async {
        dictationTask?.cancel()
        dictationTask = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil
        recorder.stop()
        guard let client = asrClient else {
            isDictating = false
            return
        }
        asrClient = nil
        isDictating = false
        do {
            let finalText = try await client.finish()
            await client.cancel()
            if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let base = dictationBaseText
                let separator = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
                inputText = base + separator + finalText
            }
        } catch is CancellationError {
            // Cancelled quietly.
        } catch {
            await client.cancel()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Read the translation aloud (result card speaker)

    @State private var isSpeaking = false
    @State private var speakTask: Task<Void, Never>?
    @State private var playbackPollTask: Task<Void, Never>?

    @MainActor
    private func toggleSpeak() {
        if isSpeaking {
            speakTask?.cancel()
            speakTask = nil
            playbackPollTask?.cancel()
            playbackPollTask = nil
            isSpeaking = false
            player.stop()
        } else {
            speakTask = Task { await speakTranslation() }
        }
    }

    @MainActor
    private func speakTranslation() async {
        guard let config = voiceConfig else {
            errorMessage = "语音未配置：去设置里填火山豆包的 AppID 和 Access Token。"
            return
        }
        let text = segments.map(\.translation).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSpeaking = true
        // My voice first, then Doubao one-shot — same order as the
        // conversation page.
        if await MyVoice.isEnabled(),
           let apiKey = await DashScopeStore.loadKey(),
           let voiceID = await QwenVoiceStore.loadVoiceID() {
            do {
                let workspaceID = await DashScopeStore.loadWorkspaceID()
                let settings = VoiceSettings()
                let audio = try await QwenVoiceClone.synthesize(apiKey: apiKey, workspaceID: workspaceID, text: text, voiceID: voiceID, rate: settings.speechRate)
                try playAndTrack(audio)
                return
            } catch is CancellationError {
                isSpeaking = false
                speakTask = nil
                return
            } catch {
                // Fall through to the Doubao path.
            }
        }
        do {
            let settings = VoiceSettings()
            let audio = try await VolcanoTTSClient(config: config).synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate)
            try playAndTrack(audio)
        } catch is CancellationError {
            isSpeaking = false
            speakTask = nil
        } catch {
            isSpeaking = false
            speakTask = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Play one-shot audio and keep the speaker button in the playing
    /// state until the player actually stops.
    @MainActor
    private func playAndTrack(_ audio: Data) throws {
        try player.play(data: audio)
        playbackPollTask?.cancel()
        playbackPollTask = Task {
            while !Task.isCancelled && player.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !Task.isCancelled {
                isSpeaking = false
                speakTask = nil
            }
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
        // S24: a long translation must not let the screen lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isTranslating = false
            translationTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
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
            // F1: one history row per model that actually translated —
            // booking the mixed total under the primary model priced
            // Qwen-MT fallback tokens at DeepSeek rates.
            let usageByModel = pipeline.lastUsageByModel
            let models = usageByModel.isEmpty ? [profile.model] : [profile.model] + usageByModel.keys.filter { $0 != profile.model }.sorted()
            for model in models {
                let usage = usageByModel[model] ?? [:]
                let isFallback = model != profile.model
                modelContext.insert(TransformHistory(
                    providerID: isFallback ? (fallback?.profile.id ?? profile.id) : profile.id,
                    sourceExcerpt: TextExcerpt.make(inputText),
                    resultExcerpt: TextExcerpt.make(results.map(\.translation).joined(separator: "\n")),
                    providerName: isFallback ? (fallback?.profile.name ?? profile.name) : profile.name,
                    model: model,
                    action: .translate,
                    targetLanguage: targetLanguage,
                    status: outcome.isComplete
                        ? (pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success")
                        : "partial · 第 \(outcome.failedSegmentIndex! + 1) 段失败",
                    promptTokens: usage["prompt_tokens"] ?? 0,
                    completionTokens: usage["completion_tokens"] ?? 0,
                    totalTokens: usage["total_tokens"] ?? 0
                ))
            }
            try? modelContext.save()
        } catch is CancellationError {
            // S24: cancelled via 取消 — finished segments stay on
            // screen, no error message.
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
