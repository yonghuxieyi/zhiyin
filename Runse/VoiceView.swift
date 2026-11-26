import RunseCore
import SwiftData
import SwiftUI
import UIKit

/// Voice translation: speak, the app recognizes what was said (streaming
/// ASR), translates it, and reads the translation aloud (streaming TTS).
/// Direction is automatic: Chinese speech translates to English, English
/// speech to Chinese. The Volcano AppID and Access Token are read from
/// the keychain; without them this screen shows the setup form.
struct VoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]

    @State private var config: VolcanoVoiceConfig?
    @State private var configChecked = false
    @State private var appIDField = ""
    @State private var tokenField = ""
    @State private var configMessage: String?

    @State private var phase: VoicePhase = .idle
    @State private var transcript = ""
    @State private var translation = ""
    @State private var errorMessage: String?
    @State private var lastAudio: Data?
    @State private var isPlaying = false
    @State private var speakerID = VoiceSettings().speakerID
    @State private var speechRate = VoiceSettings().speechRate
    @State private var useMyVoice = VoiceSettings().useMyVoice
    @State private var hasMyVoice = false

    private let pipeline = TranslationPipeline()
    private let player = AudioPlayer()
    private let streamingPlayer = StreamingAudioPlayer()
    private let recorder = VoiceRecorder()
    @State private var asrClient: VolcanoASRClient?
    // N6: the two background loops must be cancellable handles, or
    // they keep running after the page is left.
    @State private var transcriptTask: Task<Void, Never>?
    @State private var audioFeedTask: Task<Void, Never>?
    // S24: stored handle for the stop/translate run — the 取消
    // button (shown while translating) cancels it.
    @State private var stopTask: Task<Void, Never>?
    /// S14: one streaming TTS connection reused across sentences
    /// (the client serves many sessions per connection); dropped on
    /// error so a broken socket does not poison later sentences, and
    /// on disappear / config change.
    @State private var streamingTTSClient: VolcanoStreamingTTSClient?
    @State private var playbackPollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if !configChecked {
                    Section { ProgressView("正在检查语音配置") }
                } else if config == nil {
                    Section("语音未配置") {
                        Text("语音识别和合成走火山豆包。AppID 和 Access Token 在火山语音控制台的 API 服务中心底部查看（点眼睛显示明文），填在这里，只存手机钥匙串。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("AppID", text: $appIDField)
                            .textInputAutocapitalization(.never)
                        SecureField("Access Token", text: $tokenField)
                        Button("保存语音配置") {
                            Task { await saveConfig() }
                        }
                        .disabled(appIDField.isEmpty || tokenField.isEmpty)
                        if let configMessage {
                            Text(configMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("说话翻译") {
                        Text(phase.hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                Task { await startListening() }
                            } label: {
                                Label("开始说话", systemImage: "mic")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(phase != .idle && phase != .done)

                            Button {
                                stopTask = Task { await stopListening() }
                            } label: {
                                Label("结束", systemImage: "stop")
                            }
                            .buttonStyle(.bordered)
                            .disabled(phase != .listening)

                            if phase == .translating {
                                Button {
                                    stopTask?.cancel()
                                } label: {
                                    Label("取消", systemImage: "xmark.circle")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if phase == .listening || phase == .translating {
                            ProgressView()
                        }
                    }

                    Section("声音") {
                        Picker("声音", selection: $speakerID) {
                            Section("女声") {
                                ForEach(DoubaoSpeaker.all.filter { $0.gender == .female }) { speaker in
                                    Text(speaker.name).tag(speaker.id)
                                }
                            }
                            Section("男声") {
                                ForEach(DoubaoSpeaker.all.filter { $0.gender == .male }) { speaker in
                                    Text(speaker.name).tag(speaker.id)
                                }
                            }
                        }
                        .onChange(of: speakerID) { _, value in
                            var settings = VoiceSettings()
                            settings.speakerID = value
                        }
                        HStack {
                            Text("语速")
                            Slider(value: $speechRate, in: 0.5...2.0, step: 0.05)
                                .onChange(of: speechRate) { _, value in
                                    var settings = VoiceSettings()
                                    settings.speechRate = value
                                }
                            Text("×\(String(format: "%.2f", speechRate))")
                                .monospacedDigit()
                        }
                    }

                    Section("我的声音") {
                        NavigationLink("我的声音") {
                            MyVoiceView()
                        }
                        Toggle("用我的声音朗读", isOn: $useMyVoice)
                            .disabled(!hasMyVoice)
                            .onChange(of: useMyVoice) { _, value in
                                var settings = VoiceSettings()
                                settings.useMyVoice = value
                            }
                        if !hasMyVoice {
                            Text("录 10–30 秒就能复刻自己的声音。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("面对面") {
                        NavigationLink("面对面对话") {
                            FaceToFaceView()
                        }
                        Text("手机放中间，上下分屏，两个人各拿一边说话。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if !transcript.isEmpty {
                        Section("识别结果") {
                            Text(transcript)
                        }
                    }

                    if !translation.isEmpty {
                        Section("译文") {
                            Text(translation)
                            Button {
                                playTranslation()
                            } label: {
                                Label(isPlaying ? "正在播放" : "播放译文", systemImage: "speaker.wave.2")
                            }
                            .disabled(translation.isEmpty)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        // N7: denied mic permission gets a one-tap way
                        // to Settings instead of just a message.
                        if errorMessage.hasPrefix("麦克风权限未开启") {
                            Button("去设置打开麦克风权限") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .font(.footnote)
                        }
                    }

                    Section("语音配置") {
                        Text("已配置 AppID \(maskedAppID)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("清除语音配置", role: .destructive) {
                            Task { await clearConfig() }
                        }
                    }
                }
            }
            .navigationTitle("语音")
            .task {
                config = await VolcanoVoiceStore.load()
                configChecked = true
                hasMyVoice = await QwenVoiceStore.loadVoiceID() != nil
            }
            // S15: refresh on every appear — after cloning a voice in
            // MyVoiceView and coming back, the toggle used to stay
            // disabled until the tab was re-entered.
            .onAppear {
                Task { hasMyVoice = await QwenVoiceStore.loadVoiceID() != nil }
            }
            .onDisappear {
                // N6: leaving the page must stop the mic / ASR socket,
                // or recording keeps uploading with no UI and the mic
                // indicator stays on.
                if phase == .listening {
                    Task { await stopListening() }
                }
                // S14: drop the reused streaming TTS connection too.
                playbackPollTask?.cancel()
                playbackPollTask = nil
                isPlaying = false
                if let client = streamingTTSClient {
                    streamingTTSClient = nil
                    Task { await client.disconnect() }
                }
            }
        }
    }

    private var maskedAppID: String {
        guard let appID = config?.appID else { return "" }
        if appID.count <= 4 { return "****" }
        return String(appID.prefix(2)) + "****" + String(appID.suffix(2))
    }

    @MainActor
    private func saveConfig() async {
        let trimmedAppID = appIDField.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await VolcanoVoiceStore.save(VolcanoVoiceConfig(appID: trimmedAppID, accessToken: trimmedToken))
            config = VolcanoVoiceConfig(appID: trimmedAppID, accessToken: trimmedToken)
            tokenField = ""
            configMessage = "已保存到钥匙串。"
            // S14: the stored streaming client holds the old config.
            if let client = streamingTTSClient {
                streamingTTSClient = nil
                await client.disconnect()
            }
        } catch {
            configMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func clearConfig() async {
        try? await VolcanoVoiceStore.clear()
        config = nil
        appIDField = ""
        tokenField = ""
        // S14: the stored streaming client holds the old config.
        if let client = streamingTTSClient {
            streamingTTSClient = nil
            await client.disconnect()
        }
    }

    @MainActor
    private func startListening() async {
        guard let config else { return }
        errorMessage = nil
        transcript = ""
        translation = ""
        lastAudio = nil
        phase = .listening
        do {
            // N7: check the mic before opening the ASR session — a
            // denied mic must not burn a billable ASR start first.
            try await VoiceRecorder.requireMicrophonePermission()
            let client = VolcanoASRClient(config: config)
            asrClient = client
            let transcriptStream = try await client.start()
            transcriptTask = Task {
                for await (text, _) in transcriptStream {
                    transcript = text
                }
            }
            let audioStream = try await recorder.start()
            audioFeedTask = Task {
                for await chunk in audioStream {
                    try? await client.sendAudio(chunk)
                }
            }
        } catch {
            transcriptTask?.cancel()
            transcriptTask = nil
            audioFeedTask?.cancel()
            audioFeedTask = nil
            await asrClient?.cancel()
            asrClient = nil
            phase = .idle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func stopListening() async {
        // S24: a long translation must not let the screen lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            stopTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        transcriptTask?.cancel()
        transcriptTask = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil
        recorder.stop()
        guard let client = asrClient else {
            phase = .idle
            return
        }
        asrClient = nil
        phase = .translating
        do {
            let finalText = try await client.finish()
            await client.cancel()
            transcript = finalText
            guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .done
                errorMessage = "没有识别到说话内容。"
                return
            }
            try await translateAndSpeak(finalText)
            phase = .done
        } catch is CancellationError {
            // S24: cancelled via 取消 — the partial translation stays
            // on screen, no error message.
            phase = .done
        } catch {
            phase = .done
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func translateAndSpeak(_ text: String) async throws {
        let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
        let profile = request.profile
        let apiKey = request.apiKey
        let template = request.template
        let target = TextLanguage.detect(text).translationTarget
        let parts = TextSegmenter.segments(for: text, maxChars: TextSegmenter.maxChars(for: profile))
        var partials = Array(repeating: "", count: parts.count)
        let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
        // S1: partial outcome — a segment that fails mid-run keeps the
        // finished part on screen instead of throwing it all away.
        let outcome = try await pipeline.translatePartial(
            segments: parts,
            profile: profile,
            apiKey: apiKey,
            targetLanguage: target,
            template: template,
            glossary: glossaryEntries,
            tone: SettingsStore().translationTone,
            fallbackProfile: fallback?.profile,
            fallbackAPIKey: fallback?.apiKey
        ) { index, partial in
            partials[index] = partial
            translation = partials.joined(separator: "\n")
        }
        let results = outcome.results
        translation = results.map(\.translation).joined(separator: "\n")
        if let failedIndex = outcome.failedSegmentIndex, let error = outcome.error {
            errorMessage = "第 \(failedIndex + 1) 段翻译失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)（已译部分已保留）"
        }
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
                sourceExcerpt: TextExcerpt.make(text),
                resultExcerpt: TextExcerpt.make(translation),
                providerName: isFallback ? (fallback?.profile.name ?? profile.name) : profile.name,
                model: model,
                action: .translate,
                targetLanguage: target,
                status: outcome.isComplete
                    ? (pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success")
                    : "partial · 第 \(outcome.failedSegmentIndex! + 1) 段失败",
                promptTokens: usage["prompt_tokens"] ?? 0,
                completionTokens: usage["completion_tokens"] ?? 0,
                totalTokens: usage["total_tokens"] ?? 0
            ))
        }
        try? modelContext.save()
        // Read the translation aloud, streaming (清单 12): audio starts
        // ~0.5 s in instead of ~9 s for a finished MP3. If streaming
        // fails, fall back to the async API; the text stays either way.
        if let config {
            do {
                try await speakStreaming(translation, config: config)
            } catch let error as CancellationError {
                // S24: a cancel during TTS must propagate to
                // stopListening, not fall through to the async
                // fallback and end as a spurious "synthesis failed".
                throw error
            } catch {
                do {
                    let audio = try await VolcanoTTSClient(config: config).synthesize(text: translation, speaker: speakerID, speechRate: speechRate)
                    lastAudio = audio
                    playTranslation()
                } catch let error as CancellationError {
                    throw error
                } catch {
                    errorMessage = "译文已出，但语音合成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }

    /// Streams `text` through the bidirectional TTS WebSocket and plays
    /// the PCM as it arrives. When "my voice" is switched on, synthesis
    /// goes through the cloned Qwen voice instead (MP3, played when
    /// ready). Throws when the stream cannot start, so the caller can
    /// fall back to the async API.
    @MainActor
    private func speakStreaming(_ text: String, config: VolcanoVoiceConfig) async throws {
        if await MyVoice.isEnabled() {
            guard let apiKey = await DashScopeStore.loadKey(),
                  let voiceID = await QwenVoiceStore.loadVoiceID() else {
                throw QwenVoiceError.notConfigured("DashScope Key 或音色")
            }
            let workspaceID = await DashScopeStore.loadWorkspaceID()
            let audio = try await QwenVoiceClone.synthesize(apiKey: apiKey, workspaceID: workspaceID, text: text, voiceID: voiceID, rate: speechRate)
            lastAudio = audio
            playTranslation()
            return
        }
        // S14: reuse the page-level streaming connection instead of
        // a fresh connect per sentence.
        let client = try await sharedStreamingTTSClient(config: config)
        try streamingPlayer.start()
        isPlaying = true
        do {
            try await client.synthesize(text: text, speaker: speakerID, speechRate: speechRate) { pcm in
                streamingPlayer.enqueue(pcm)
            }
        } catch let error as CancellationError {
            // S24: cancelling must not drop the shared connection —
            // it is still healthy, only the sentence was cancelled.
            // But the "正在播放" flag was set before synthesize, and
            // trackPlaybackEnd() only runs on the success path — reset
            // it here or it stays stuck after a cancel.
            isPlaying = false
            throw error
        } catch {
            // A broken connection must not poison later sentences.
            await dropStreamingTTSClient()
            isPlaying = false
            throw error
        }
        trackPlaybackEnd()
    }

    /// S14: one streaming TTS connection per page — the client can
    /// serve many sessions, so a fresh connect per sentence paid a
    /// handshake + delay every time.
    private func sharedStreamingTTSClient(config: VolcanoVoiceConfig) async throws -> VolcanoStreamingTTSClient {
        if let existing = streamingTTSClient { return existing }
        let created = VolcanoStreamingTTSClient(config: config)
        try await created.connect()
        streamingTTSClient = created
        return created
    }

    private func dropStreamingTTSClient() async {
        if let client = streamingTTSClient {
            streamingTTSClient = nil
            await client.disconnect()
        }
    }

    /// S14: poll the real playback state instead of a hardcoded 10 s
    /// sleep — long audio used to leave "正在播放" stuck on, short
    /// audio waited the full 10 s to clear.
    private func trackPlaybackEnd() {
        playbackPollTask?.cancel()
        playbackPollTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled {
                let playing = streamingPlayer.isPlaying || player.isPlaying
                if !playing { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !Task.isCancelled {
                isPlaying = false
            }
        }
    }

    @MainActor
    private func playTranslation() {
        if let lastAudio {
            // Async fallback path: replay the finished MP3.
            do {
                try player.play(data: lastAudio)
                isPlaying = true
                trackPlaybackEnd()
            } catch {
                errorMessage = "播放失败：\(error.localizedDescription)"
            }
            return
        }
        guard !translation.isEmpty, let config else { return }
        Task {
            // S14: a failed replay used to be swallowed silently —
            // no sound and no message.
            do {
                try await speakStreaming(translation, config: config)
            } catch {
                errorMessage = "播放失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}

enum VoicePhase {
    case idle, listening, translating, done

    var hint: String {
        switch self {
        case .idle: "点开始说话，对着手机说；说完点结束。"
        case .listening: "正在听，边说边识别……"
        case .translating: "正在翻译和合成语音……"
        case .done: "完成。再说一段点开始说话。"
        }
    }
}
