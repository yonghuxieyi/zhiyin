import RunseCore
import SwiftData
import SwiftUI
import UIKit

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
    // N6: the two background loops must be cancellable handles, or
    // they keep running after the page is left.
    @State private var transcriptTask: Task<Void, Never>?
    @State private var audioFeedTask: Task<Void, Never>?

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
                    .disabled((isWorking || listeningSide != nil) && listeningSide != .them)
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
                        .disabled((isWorking || listeningSide != nil) && listeningSide != .me)
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
                }
                .padding()
            }
        }
        .navigationTitle("面对面")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            config = await VolcanoVoiceStore.load()
        }
        .onDisappear {
            // N6: leaving the page must stop the mic / ASR socket,
            // or recording keeps uploading with no UI and the mic
            // indicator stays on.
            if listeningSide != nil {
                Task { await stopListening() }
            }
        }
    }

    @MainActor
    private func toggleListening(side: FaceSide) async {
        if listeningSide == side {
            await stopListening()
            return
        }
        // N8: switching sides while the other side is listening
        // would open a second recorder + ASR client (the other
        // button stays enabled because isWorking is false while
        // listening). Stop the current side first.
        if listeningSide != nil, listeningSide != side {
            await stopListening()
        }
        guard let config else {
            errorMessage = "语音未配置。"
            return
        }
        errorMessage = nil
        liveTranscript = ""
        listeningSide = side
        do {
            // N7: check the mic before opening the ASR session — a
            // denied mic must not burn a billable ASR start first.
            try await VoiceRecorder.requireMicrophonePermission()
            let client = VolcanoASRClient(config: config)
            asrClient = client
            let stream = try await client.start()
            transcriptTask = Task {
                for await (text, _) in stream {
                    liveTranscript = text
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
            listeningSide = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func stopListening() async {
        transcriptTask?.cancel()
        transcriptTask = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil
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
        let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
        let profile = request.profile
        let apiKey = request.apiKey
        let template = request.template
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
                status: "success",
                promptTokens: usage["prompt_tokens"] ?? 0,
                completionTokens: usage["completion_tokens"] ?? 0,
                totalTokens: usage["total_tokens"] ?? 0
            ))
        }
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
