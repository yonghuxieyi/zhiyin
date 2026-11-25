import RunseCore
import SwiftData
import SwiftUI

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

    private let pipeline = TranslationPipeline()
    private let player = AudioPlayer()
    private let recorder = VoiceRecorder()
    @State private var asrClient: VolcanoASRClient?

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
                                Task { await stopListening() }
                            } label: {
                                Label("结束", systemImage: "stop")
                            }
                            .buttonStyle(.bordered)
                            .disabled(phase != .listening)
                        }
                        if phase == .listening {
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
                            .disabled(lastAudio == nil)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
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
            let client = VolcanoASRClient(config: config)
            asrClient = client
            let transcriptStream = try await client.start()
            Task {
                for await (text, _) in transcriptStream {
                    transcript = text
                }
            }
            let audioStream = try recorder.start()
            Task {
                for await chunk in audioStream {
                    try? await client.sendAudio(chunk)
                }
            }
        } catch {
            await asrClient?.cancel()
            asrClient = nil
            phase = .idle
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func stopListening() async {
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
        } catch {
            phase = .done
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func translateAndSpeak(_ text: String) async throws {
        guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
            throw LLMProviderError.invalidURL
        }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
        guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
        let template = templates.first { $0.action == .translate }
            ?? PromptTemplate.builtIns().first { $0.action == .translate }!
        let target = TextLanguage.detect(text).translationTarget
        let parts = TextSegmenter.segments(for: text, maxChars: TextSegmenter.maxChars(for: profile))
        var partials = Array(repeating: "", count: parts.count)
        let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve(profiles: profiles)
        let results = try await pipeline.translate(
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
        translation = results.map(\.translation).joined(separator: "\n")
        let usage = pipeline.lastUsage
        modelContext.insert(TransformHistory(
            providerID: profile.id,
            sourceExcerpt: TextExcerpt.make(text),
            resultExcerpt: TextExcerpt.make(translation),
            providerName: profile.name,
            model: profile.model,
            action: .translate,
            targetLanguage: target,
            status: pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success",
            promptTokens: usage["prompt_tokens"] ?? 0,
            completionTokens: usage["completion_tokens"] ?? 0,
            totalTokens: usage["total_tokens"] ?? 0
        ))
        try? modelContext.save()
        // Read the translation aloud. If TTS fails the text stays.
        if let config {
            do {
                let audio = try await VolcanoTTSClient(config: config).synthesize(text: translation, speaker: speakerID, speechRate: speechRate)
                lastAudio = audio
                playTranslation()
            } catch {
                errorMessage = "译文已出，但语音合成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func playTranslation() {
        guard let lastAudio else { return }
        do {
            try player.play(data: lastAudio)
            isPlaying = true
            Task {
                try? await Task.sleep(for: .seconds(10))
                await MainActor.run { isPlaying = player.isPlaying }
            }
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
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
