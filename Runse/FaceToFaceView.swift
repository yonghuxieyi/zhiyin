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
    // S24: stored handle for the toggle/stop run — the 取消 button
    // (shown while translating) cancels it.
    @State private var toggleTask: Task<Void, Never>?
    /// S14: one streaming TTS connection reused across turns (the
    /// client serves many sessions per connection); dropped on error
    /// so a broken socket does not poison later turns, and on
    /// disappear.
    @State private var streamingTTSClient: VolcanoStreamingTTSClient?
    /// Item 7 (UI redesign): single-person mode is the default
    /// (21:33); the view picker switches to face-to-face.
    @State private var isSingleMode = true
    @State private var showingViewPicker = false
    /// Item 8 (UI redesign): continuous mode, entered by long-pressing
    /// the mic for 1 second (21:54, 22:59). Tap pauses / resumes in
    /// continuous mode; long-press again exits. The streaming engine
    /// itself arrives in item 9 — until then a turn uses the existing
    /// one-shot listen → translate → speak loop and restarts itself.
    @State private var isContinuousMode = false
    @State private var isContinuousPaused = false
    @State private var continuousSide: FaceSide = .me
    @State private var continuousElapsed: TimeInterval = 0
    @State private var continuousTickerTask: Task<Void, Never>?

    private var latestTurn: FaceTurn? { turns.last }

    var body: some View {
        NavigationStack {
            Group {
                if isSingleMode {
                    singleModeView
                } else {
                    dualModeView
                }
            }
            .navigationTitle(isSingleMode ? "对话" : "面对面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isSingleMode ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if isSingleMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingViewPicker = true
                        } label: {
                            Image(systemName: "person")
                        }
                        .accessibilityLabel("视图")
                    }
                }
            }
        }
        .sheet(isPresented: $showingViewPicker) {
            ConversationViewPicker(isSingleMode: $isSingleMode)
        }
        // Item 8: switching single / face-to-face ends a continuous
        // session — its controls live on the mic of the current mode.
        .onChange(of: isSingleMode) { _, _ in
            if isContinuousMode {
                stopContinuousMode()
            }
        }
        .task {
            config = await VolcanoVoiceStore.load()
        }
        .onDisappear {
            // Item 8: leaving the page ends the continuous session
            // (21:58: exiting closes voice) and stops its timer.
            if isContinuousMode {
                isContinuousMode = false
                isContinuousPaused = false
                continuousElapsed = 0
                stopContinuousTicker()
            }
            // N6: leaving the page must stop the mic / ASR socket,
            // or recording keeps uploading with no UI and the mic
            // indicator stays on.
            if listeningSide != nil {
                Task { await stopListening() }
            }
            // S14: drop the reused streaming TTS connection too.
            if let client = streamingTTSClient {
                streamingTTSClient = nil
                Task { await client.disconnect() }
            }
        }
    }

    /// Item 7: single-person mode (the default, 21:33) — a
    /// conversation list with the mic at the bottom of the screen
    /// (23:28). No language-pair row, no middle instruction card,
    /// no bottom continuous-mode card (23:21 — none of the three
    /// exist in this view, so single mode is built without them);
    /// continuous mode stays on the mic long-press (item 8).
    private var singleModeView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.source)
                                .font(.body)
                            Text(turn.translation)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !liveTranscript.isEmpty {
                        Text(liveTranscript)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    if turns.isEmpty && liveTranscript.isEmpty {
                        Text("点下面的麦克风说话，译文会出现在这里。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    }
                }
                .padding()
            }
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button {
                        Task { await replayLatest() }
                    } label: {
                        Label("重播", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                    // Item 8: replay would talk over a live continuous
                    // session, so it is off while one is running.
                    .disabled(latestTurn == nil || isWorking || isContinuousMode)
                    Spacer()
                    singleMicButton
                    Spacer()
                    if isWorking {
                        Button {
                            toggleTask?.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Color.clear.frame(width: 76, height: 36)
                    }
                    Spacer()
                }
                errorBlock
            }
            .padding()
        }
    }

    /// Item 7: the mic-permission error + Settings shortcut,
    /// shared by both modes (was inline in the dual layout).
    @ViewBuilder
    private var errorBlock: some View {
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

    /// Item 7: face-to-face mode — the original split layout
    /// (top half rotated 180° for the person across).
    private var dualModeView: some View {
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
                        toggleTask = Task { await toggleListening(side: .them) }
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
                            toggleTask = Task { await toggleListening(side: .me) }
                        } label: {
                            Label(listeningSide == .me ? "正在听…" : "我说", systemImage: "mic")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((isWorking || listeningSide != nil) && listeningSide != .me)
                        if isWorking {
                            Button {
                                toggleTask?.cancel()
                            } label: {
                                Label("取消", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button {
                            Task { await replayLatest() }
                        } label: {
                            Label("重播", systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)
                        .disabled(latestTurn == nil || isWorking)
                    }
                    errorBlock
                }
                .padding()
            }
        }
        // Item 7 (23:24): in face-to-face mode the view button
        // moves to the bottom-left corner, and the bottom-right
        // becomes an X that goes back to single mode.
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    showingViewPicker = true
                } label: {
                    Image(systemName: "person.2")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("视图")
                Spacer()
                Button {
                    isSingleMode = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("返回单人模式")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    /// Item 7: single-mode mic — one button for both directions
    /// (direction is auto-detected per turn). Tap to start, tap
    /// again to stop; long-press for continuous mode is item 8.
    @MainActor
    private func toggleSingleListening() async {
        if listeningSide != nil {
            await stopListening()
            return
        }
        await toggleListening(side: .me)
    }

    /// Item 8: the single-mode mic. Tap starts / stops (21:58);
    /// long-press 1 second enters / exits continuous mode (21:54,
    /// 22:59); in continuous mode tap pauses / resumes. Tap and
    /// long-press are exclusive gestures — a quick tap never fires
    /// the long-press, and a 1-second hold never fires the tap.
    private var singleMicButton: some View {
        Group {
            if isContinuousMode {
                // 23:49: in continuous mode the mic icon becomes the
                // elapsed time, digits only.
                VStack(spacing: 2) {
                    if isContinuousPaused {
                        // 00:20 (final): paused — time at the top of
                        // the button, the enlarged pause glyph
                        // centered below it. The translucent-overlay
                        // and arc versions are void.
                        Text(continuousTimeText)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Image(systemName: "pause.fill")
                            .font(.system(size: 34))
                    } else {
                        Text(continuousTimeText)
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                }
                .frame(width: 96, height: 96)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            } else {
                Image(systemName: listeningSide != nil ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
        }
        .onTapGesture {
            if isContinuousMode {
                toggleContinuousPause()
            } else if !isWorking {
                toggleTask = Task { await toggleSingleListening() }
            }
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            if isContinuousMode {
                stopContinuousMode()
            } else {
                startContinuousMode(side: .me)
            }
        }
        .accessibilityLabel(singleMicLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var singleMicLabel: String {
        if isContinuousMode {
            return isContinuousPaused ? "继续连续对话" : "暂停连续对话"
        }
        return listeningSide != nil ? "停止" : "开始说话"
    }

    /// Item 8: elapsed time in the continuous-mode button, "0:26" style.
    private var continuousTimeText: String {
        let total = Int(continuousElapsed)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Item 8: haptics for the mic (23:53) — medium on entering
    /// continuous mode, light on pause / resume.
    private func micHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Item 8: long-press (1s) enters continuous mode (21:54, 22:59).
    @MainActor
    private func startContinuousMode(side: FaceSide) {
        guard !isContinuousMode, !isWorking else { return }
        micHaptic(.medium)
        continuousSide = side
        isContinuousMode = true
        isContinuousPaused = false
        continuousElapsed = 0
        startContinuousTicker()
        toggleTask = Task { await toggleListening(side: side) }
    }

    /// Item 8: long-press again stops continuous mode (21:54).
    @MainActor
    private func stopContinuousMode() {
        guard isContinuousMode else { return }
        isContinuousMode = false
        isContinuousPaused = false
        continuousElapsed = 0
        stopContinuousTicker()
        if listeningSide != nil {
            toggleTask = Task { await stopListening() }
        }
    }

    /// Item 8: tap in continuous mode pauses / resumes (21:54).
    /// Pausing finishes the current utterance (its content is kept)
    /// and does not start the next turn until resumed.
    @MainActor
    private func toggleContinuousPause() {
        guard isContinuousMode else { return }
        micHaptic(.light)
        if isContinuousPaused {
            isContinuousPaused = false
            startContinuousTicker()
            // If a turn is still translating, its end restarts
            // listening via maybeContinueContinuous — starting a
            // second session now would hear the speaker.
            if listeningSide == nil && !isWorking {
                toggleTask = Task { await toggleListening(side: continuousSide) }
            }
        } else {
            isContinuousPaused = true
            stopContinuousTicker()
            if listeningSide != nil {
                toggleTask = Task { await stopListening() }
            }
        }
    }

    /// Item 8: after a turn ends, continuous mode starts the next
    /// turn automatically (until paused / exited). The streaming
    /// engine itself arrives in item 9.
    @MainActor
    private func maybeContinueContinuous() async {
        guard isContinuousMode, !isContinuousPaused, !Task.isCancelled else { return }
        await toggleListening(side: continuousSide)
    }

    @MainActor
    private func startContinuousTicker() {
        continuousTickerTask?.cancel()
        continuousTickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                continuousElapsed += 1
            }
        }
    }

    @MainActor
    private func stopContinuousTicker() {
        continuousTickerTask?.cancel()
        continuousTickerTask = nil
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
            // Item 8: a cancel while (re)starting listening stops
            // quietly instead of showing a cancellation error — the
            // auto-restarted listen runs while isWorking is still
            // true, so the 取消 button can hit it.
            if !(error is CancellationError) {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @MainActor
    private func stopListening() async {
        // S24: a long translation must not let the screen lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            toggleTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        transcriptTask?.cancel()
        transcriptTask = nil
        audioFeedTask?.cancel()
        audioFeedTask = nil
        recorder.stop()
        guard let client = asrClient else {
            listeningSide = nil
            // Item 8: nothing was listening — a continuous session
            // still starts its next turn from here.
            await maybeContinueContinuous()
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
        } catch is CancellationError {
            // S24: cancelled via 取消 — the finished turn stays in
            // the list, no error message.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Item 8: a finished turn restarts listening while the
        // continuous session is running and not paused.
        await maybeContinueContinuous()
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
        // S1: partial outcome — a segment that fails mid-run keeps the
        // finished part in the turn instead of dropping the whole round.
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
        ) { _, _ in }
        let results = outcome.results
        let translation = results.map(\.translation).joined(separator: "\n")
        if let failedIndex = outcome.failedSegmentIndex, let error = outcome.error {
            errorMessage = "第 \(failedIndex + 1) 段翻译失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)（已译部分已保留）"
        }
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
                status: outcome.isComplete ? "success" : "partial · 第 \(outcome.failedSegmentIndex! + 1) 段失败",
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
            } catch is CancellationError {
                // S24: a cancel during TTS stops quietly — it must
                // not fall through to the next synthesis path or end
                // as a spurious "语音合成失败".
                return
            } catch {
                // Fall through to the Doubao paths.
            }
        }
        do {
            // S14: reuse the page-level streaming connection instead
            // of a fresh connect per turn.
            let client: VolcanoStreamingTTSClient
            if let existing = streamingTTSClient {
                client = existing
            } else {
                let created = VolcanoStreamingTTSClient(config: config)
                try await created.connect()
                streamingTTSClient = created
                client = created
            }
            do {
                try streamingPlayer.start()
                let settings = VoiceSettings()
                try await client.synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate) { pcm in
                    streamingPlayer.enqueue(pcm)
                }
            } catch is CancellationError {
                // S24: cancelling must not poison the shared
                // connection (the generic catch below disconnects it).
                return
            } catch {
                // A broken connection must not poison later turns.
                if let stored = streamingTTSClient {
                    streamingTTSClient = nil
                    await stored.disconnect()
                }
                throw error
            }
        } catch is CancellationError {
            // S24: a cancel during connect stops quietly.
            return
        } catch {
            do {
                let settings = VoiceSettings()
                let audio = try await VolcanoTTSClient(config: config).synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate)
                try player.play(data: audio)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "语音合成失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }
}

/// Item 7 (UI redesign, 23:01): the Apple-style view picker —
/// 面对面 and 单人 (the old "对话" label is now "单人").
/// Opened from the top-left view button in single mode, and from
/// the bottom-left button in face-to-face mode.
private struct ConversationViewPicker: View {
    @Binding var isSingleMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    isSingleMode = false
                    dismiss()
                } label: {
                    HStack {
                        Label("面对面", systemImage: "person.2")
                        Spacer()
                        if !isSingleMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    isSingleMode = true
                    dismiss()
                } label: {
                    HStack {
                        Label("单人", systemImage: "person")
                        Spacer()
                        if isSingleMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            .navigationTitle("视图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
