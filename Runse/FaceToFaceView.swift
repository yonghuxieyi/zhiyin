import RunseCore
import SwiftData
import SwiftUI

/// Face-to-face mode (清单 9): two people, one phone. The phone lies
/// between them; the top half is rotated 180° so the person across can
/// read it. Each side taps its own mic, speaks, and the translation
/// appears on the other side — and is read aloud.
///
/// Direction is automatic per turn (Chinese speech → English,
/// English speech → Chinese). Playback uses streaming TTS when
/// available, with the async API as fallback (same as the voice tab).
struct FaceTurn: Identifiable {
    let id = UUID()
    var speaker: FaceSide
    var source: String
    var translation: String
}

enum FaceSide: String {
    case me
    case them

    var title: String {
        switch self {
        case .me: "我"
        case .them: "对方"
        }
    }
}

struct FaceToFaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]

    @State private var config: VolcanoVoiceConfig?
    @State private var turns: [FaceTurn] = []
    @State private var listeningSide: FaceSide?
    @State private var liveTranscript = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let pipeline = TranslationPipeline()
    private let recorder = VoiceRecorder()
    private let streamingPlayer = StreamingAudioPlayer()
    private let player = AudioPlayer()
    @State private var asrClient: VolcanoASRClient?

    private var latestTurn: FaceTurn? { turns.last }

    var body: some View {
        VStack(spacing: 0) {
            // Top half: the person across. Rotated 180° so they read
            // it upright. Shows the translation big, the original small.
            ZStack {
                Color(.systemGray6)
                VStack(spacing: 12) {
                    if let turn = latestTurn {
                        Text(turn.translation)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                        Text(turn.source)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(turn.speaker == .them ? "你说的" : "对方说的")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("面对面")
                            .font(.title2)
                        Text("对方点上面的麦克风说话，译文会出现在这里。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await toggleListening(side: .them) }
                    } label: {
                        Label(listeningSide == .them ? "正在听…" : "对方说话", systemImage: "mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking && listeningSide != .them)
                }
                .padding()
            }
            .rotationEffect(.degrees(180))

            Divider()

            // Bottom half: me. Shows what I said and the translation.
            ZStack {
                Color(.systemBackground)
                VStack(spacing: 12) {
                    if let turn = latestTurn {
                        Text(turn.source)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                        Text(turn.translation)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if !liveTranscript.isEmpty {
                            Text(liveTranscript)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("点下面的麦克风说话，译文会显示在对面。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 16) {
                        Button {
                            Task { await toggleListening(side: .me) }
                        } label: {
                            Label(listeningSide == .me ? "正在听…" : "我说", systemImage: "mic")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking && listeningSide != .me)
                        Button {
                            Task { await replayLatest() }
                        } label: {
                            Label("重播", systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)
                        .disabled(latestTurn == nil || isWorking)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("面对面")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            config = await VolcanoVoiceStore.load()
        }
    }

    @MainActor
    private func toggleListening(side: FaceSide) async {
        if listeningSide == side {
            await stopListening()
            return
        }
        guard let config else {
            errorMessage = "语音未配置。"
            return
        }
        errorMessage = nil
        liveTranscript = ""
        listeningSide = side
        do {
            let client = VolcanoASRClient(config: config)
            asrClient = client
            let stream = try await client.start()
            Task {
                for await (text, _) in stream {
                    liveTranscript = text
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
            listeningSide = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func stopListening() async {
        recorder.stop()
        guard let client = asrClient else {
            listeningSide = nil
            return
        }
        asrClient = nil
        let side = listeningSide
        listeningSide = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let finalText = try await client.finish()
            await client.cancel()
            liveTranscript = ""
            guard let side, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try await translateAndSpeak(finalText, side: side)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func translateAndSpeak(_ text: String, side: FaceSide) async throws {
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
        let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
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
        ) { _, _ in }
        let translation = results.map(\.translation).joined(separator: "\n")
        turns.append(FaceTurn(speaker: side, source: text, translation: translation))
        let usage = pipeline.lastUsage
        modelContext.insert(TransformHistory(
            providerID: profile.id,
            sourceExcerpt: TextExcerpt.make(text),
            resultExcerpt: TextExcerpt.make(translation),
            providerName: profile.name,
            model: profile.model,
            action: .translate,
            targetLanguage: target,
            status: "success",
            promptTokens: usage["prompt_tokens"] ?? 0,
            completionTokens: usage["completion_tokens"] ?? 0,
            totalTokens: usage["total_tokens"] ?? 0
        ))
        try? modelContext.save()
        await speak(translation)
    }

    @MainActor
    private func replayLatest() async {
        guard let translation = latestTurn?.translation else { return }
        await speak(translation)
    }

    @MainActor
    private func speak(_ text: String) async {
        guard let config else { return }
        // My voice first, then streaming, then async — same order as
        // the voice tab.
        if await MyVoice.isEnabled(),
           let apiKey = await DashScopeStore.loadKey(),
           let voiceID = await QwenVoiceStore.loadVoiceID() {
            do {
                let workspaceID = await DashScopeStore.loadWorkspaceID()
                let settings = VoiceSettings()
                let audio = try await QwenVoiceClone.synthesize(apiKey: apiKey, workspaceID: workspaceID, text: text, voiceID: voiceID, rate: settings.speechRate)
                try player.play(data: audio)
                return
            } catch {
                // Fall through to the Doubao paths.
            }
        }
        do {
            let client = VolcanoStreamingTTSClient(config: config)
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try streamingPlayer.start()
            let settings = VoiceSettings()
            try await client.synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate) { pcm in
                streamingPlayer.enqueue(pcm)
            }
        } catch {
            do {
                let settings = VoiceSettings()
                let audio = try await VolcanoTTSClient(config: config).synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate)
                try player.play(data: audio)
            } catch {
                errorMessage = "语音合成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}
