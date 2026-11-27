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
    /// Item 9 (UI redesign): continuous mode runs on the
    /// simultaneous-interpretation engine (21:42: continuous mode IS
    /// interpretation) — single mode is one-way, face-to-face is
    /// two-way (21:51). The engine owns the mic while a session is
    /// running; the one-shot loop below is only for single turns.
    @StateObject private var interpretEngine = InterpretationEngine()
    /// Item 9: the streaming TTS client behind the engine's
    /// sequential-line speaker; disconnected when the session ends.
    @State private var continuousStreamingClient: VolcanoStreamingTTSClient?
    /// Item 8 (UI redesign): continuous mode, entered by long-pressing
    /// the mic for 1 second (21:54, 22:59). Tap pauses / resumes in
    /// continuous mode; long-press again exits.
    @State private var isContinuousMode = false
    @State private var isContinuousPaused = false
    /// 2026-11-27: the continuous session has three states —
    /// entered (long-press, not started: no engine, no ticker,
    /// no billing), started (tap: engine live, ticker running),
    /// paused (tap again). isContinuousMode covers entered +
    /// started + paused; this flag marks started/paused only.
    @State private var isContinuousStarted = false
    @State private var continuousElapsed: TimeInterval = 0
    @State private var continuousTickerTask: Task<Void, Never>?
    /// Item 11 (UI redesign, 22:51): the language card (top-right
    /// "…" on the conversation page) — the same three toggles as the
    /// translate page's card (item 5), but no settings row. The
    /// toggles are the conversation page's own SettingsStore keys
    /// (conversationPlayTranslation / conversationAutoTranslate /
    /// conversationDetectLanguage), NOT the translate page's shared
    /// ones — each card controls its own page.
    ///
    /// What each toggle does in conversation:
    /// - 播放翻译: translations are read aloud automatically.
    ///   One-shot: the turn's translation is spoken at the end of
    ///   translateAndSpeak (off → text only, 重播 still plays it).
    ///   Continuous: the engine's speaker/streaming closures check
    ///   the setting live per segment (off → subtitles only).
    /// - 自动翻译: input is translated without being asked. One-shot:
    ///   on stop, the transcript is translated at once (off → the
    ///   final text waits as a pending row with a 翻译 button).
    ///   Continuous: the engine always translates live — the mode
    ///   IS translation, so this toggle has no off state there.
    /// - 检测语言: the input language is auto-detected. One-shot:
    ///   the target comes from TextLanguage.detect (off → fixed
    ///   中文→英语). Continuous: direction is single .zhToEn /
    ///   dual .both when on, always .zhToEn when off.
    ///
    /// Defaults (decided in review): the conversation page's three
    /// default ON — speaking is for translating, and a translation
    /// is for hearing (the page's established flow: speak →
    /// translate → speak). The translate page's three stay OFF by
    /// default (item 5 — a typed passage must not auto-translate on
    /// every pause or auto-read aloud unprompted). Each page keeps
    /// its own defaults; flipping a switch in either card only
    /// affects that page.
    @State private var playTranslationEnabled = SettingsStore().conversationPlayTranslation
    @State private var autoTranslateEnabled = SettingsStore().conversationAutoTranslate
    @State private var detectLanguageEnabled = SettingsStore().conversationDetectLanguage
    @State private var showingLanguageCard = false
    /// Item 11: a finished transcript waiting for a manual 翻译 tap
    /// (自动翻译 off). Cleared by a new listen, by entering
    /// continuous mode, or by switching single / face-to-face.
    @State private var pendingTranscript: String?
    @State private var pendingSide: FaceSide?
    private let settings = SettingsStore()

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isSingleMode ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if isSingleMode {
                    // Item 10 (23:49/23:50): in continuous mode the
                    // top-left (where the view button was) shows the
                    // consumption number only, no label; the title
                    // stays centred no matter how wide the side items
                    // are, so the trailing item is an invisible block
                    // the same width as the leading one.
                    ToolbarItem(placement: .topBarLeading) {
                        Group {
                            if isContinuousMode {
                                Text(consumptionText)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .accessibilityLabel("今日已用同传分钟数")
                            } else {
                                Button {
                                    showingViewPicker = true
                                } label: {
                                    Image(systemName: "person")
                                }
                                .accessibilityLabel("视图")
                            }
                        }
                        .frame(width: 64, alignment: .leading)
                    }
                    ToolbarItem(placement: .principal) {
                        // 2026-11-27: in continuous mode the title
                        // is 同传; pausing is still continuous, so
                        // it only returns to 对话 on a real stop.
                        // The 同传 title gets a gradient in the
                        // app's green/blue-green palette; 对话
                        // stays the plain default title colour.
                        Group {
                            if isContinuousMode {
                                Text("同传")
                                    .font(.headline)
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.green, .teal, .blue],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            } else {
                                Text("对话")
                                    .font(.headline)
                            }
                        }
                    }
                    // Item 11 (22:51): the language card opens from
                    // the top-right "…". The button overlays the
                    // invisible spacer, so the overlay adds no width
                    // and the title stays centred (23:50).
                    ToolbarItem(placement: .topBarTrailing) {
                        Color.clear.frame(width: 64, height: 44)
                            .overlay(alignment: .trailing) {
                                Button {
                                    showingLanguageCard = true
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("语言选项")
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showingViewPicker) {
            ConversationViewPicker(isSingleMode: $isSingleMode)
        }
        .sheet(isPresented: $showingLanguageCard) {
            ConversationLanguageCard(
                playTranslationEnabled: $playTranslationEnabled,
                autoTranslateEnabled: $autoTranslateEnabled,
                detectLanguageEnabled: $detectLanguageEnabled
            )
        }
        // Item 8: switching single / face-to-face ends a continuous
        // session — its controls live on the mic of the current mode.
        .onChange(of: isSingleMode) { _, _ in
            if isContinuousMode {
                Task { await stopContinuousMode() }
            }
            // Item 11: a pending transcript belongs to the other
            // mode's layout; switching views discards it.
            pendingTranscript = nil
            pendingSide = nil
        }
        .onChange(of: playTranslationEnabled) { _, value in settings.conversationPlayTranslation = value }
        .onChange(of: autoTranslateEnabled) { _, value in settings.conversationAutoTranslate = value }
        .onChange(of: detectLanguageEnabled) { _, value in settings.conversationDetectLanguage = value }
        .task {
            config = await VolcanoVoiceStore.load()
        }
        .onDisappear {
            // Item 8/9: leaving the page ends the continuous session
            // (21:58: exiting closes voice) and stops its timer.
            // stopContinuousMode also persists the session history.
            if isContinuousMode {
                Task { await stopContinuousMode() }
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isContinuousMode {
                            // Item 9 (21:58): scrolling subtitles —
                            // the live engine's segments and draft.
                            ForEach(interpretEngine.segments) { segment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(segment.sourceText)
                                        .font(.body)
                                    Text(segment.translationText)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !interpretEngine.liveDraftSource.isEmpty || !interpretEngine.liveDraftTranslation.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(interpretEngine.liveDraftSource)
                                        .font(.body)
                                        .foregroundStyle(.primary.opacity(0.6))
                                    Text(interpretEngine.liveDraftTranslation)
                                        .font(.body)
                                        .foregroundStyle(.secondary.opacity(0.6))
                                }
                            }
                            if interpretEngine.segments.isEmpty && interpretEngine.liveDraftSource.isEmpty && interpretEngine.liveDraftTranslation.isEmpty {
                                // 2026-11-27: not started yet — do
                                // not claim a session is running.
                                Text(isContinuousStarted ? "连续对话进行中，说话后译文会滚动出现在这里。" : "点一下麦克风开始，说话后译文会滚动出现在这里。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 32)
                            }
                        } else {
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
                        Color.clear.frame(height: 1).id("listBottom")
                    }
                    .padding()
                }
                .onChange(of: turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("listBottom", anchor: .bottom) }
                }
                .onChange(of: interpretEngine.segments.count) { _, _ in
                    withAnimation { proxy.scrollTo("listBottom", anchor: .bottom) }
                }
                .onChange(of: interpretEngine.liveDraftSource) { _, _ in
                    guard !interpretEngine.liveDraftSource.isEmpty else { return }
                    withAnimation { proxy.scrollTo("listBottom", anchor: .bottom) }
                }
            }
            VStack(spacing: 12) {
                // Item 9 (21:51): a small sound-wave animation while
                // the continuous session is live.
                if isContinuousMode {
                    continuousWaveform
                }
                // Item 11: 自动翻译 off — the finished transcript
                // waits here with a manual 翻译 button.
                if let pendingTranscript, !isContinuousMode {
                    HStack(spacing: 8) {
                        Text(pendingTranscript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("翻译") {
                            Task { await translatePending() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    }
                }
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
        // Item 9: while a continuous session is live, surface the
        // engine's own state — connecting, its error, or the
        // sequential-line fallback — under the mic area.
        if isContinuousMode {
            if interpretEngine.phase == .connecting {
                Text("正在连接同传…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let engineError = interpretEngine.errorMessage {
                Text(engineError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if interpretEngine.mode == .fallback {
                Text("实时同传不可用，已切换到顺序语音线。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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

    /// Item 11: the pending-transcript row (自动翻译 off) for one
    /// side of the face-to-face layout — the finished text waits
    /// with a manual 翻译 button. (The top half is rotated 180°,
    /// so this row reads upright for the person across, like the
    /// rest of that half.)
    @ViewBuilder
    private func pendingRow(side: FaceSide) -> some View {
        if pendingSide == side, let pendingTranscript {
            HStack(spacing: 8) {
                Text(pendingTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("翻译") {
                    Task { await translatePending() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
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
                    if let display = dualDisplay {
                        Text(display.translation)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                        Text(display.source)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(display.speaker == .them ? "你说的" : "对方说的")
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
                    dualMicButton(side: .them)
                    pendingRow(side: .them)
                }
                .padding()
            }
            .rotationEffect(.degrees(180))

            Divider()

            // Bottom half: me. Shows what I said and the translation.
            ZStack {
                Color(.systemBackground)
                VStack(spacing: 12) {
                    if let display = dualDisplay {
                        Text(display.source)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                        Text(display.translation)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if isContinuousMode {
                            if !interpretEngine.liveDraftSource.isEmpty {
                                Text(interpretEngine.liveDraftSource)
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                        } else if !liveTranscript.isEmpty {
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
                        dualMicButton(side: .me)
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
                    // Item 11: 自动翻译 off — the finished transcript
                    // for my side waits here with a 翻译 button.
                    pendingRow(side: .me)
                    // Item 9 (21:51): sound-wave animation while the
                    // continuous session is live.
                    if isContinuousMode {
                        continuousWaveform
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
                        .liquidGlass(in: Circle())
                }
                .accessibilityLabel("视图")
                Spacer()
                Button {
                    isSingleMode = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .liquidGlass(in: Circle())
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

    /// Item 9: what the face-to-face halves show. In continuous mode
    /// the live engine's latest segment (and draft) instead of the
    /// last one-shot turn.
    private var dualDisplay: (source: String, translation: String, speaker: FaceSide)? {
        if isContinuousMode {
            if let segment = interpretEngine.segments.last {
                return (segment.sourceText, segment.translationText, segment.direction == .zhToEn ? .me : .them)
            }
            if !interpretEngine.liveDraftSource.isEmpty || !interpretEngine.liveDraftTranslation.isEmpty {
                return (interpretEngine.liveDraftSource, interpretEngine.liveDraftTranslation, .me)
            }
            return nil
        }
        if let turn = latestTurn {
            return (turn.source, turn.translation, turn.speaker)
        }
        return nil
    }

    /// Item 9: a face-to-face mic button. Tap starts / stops one-shot
    /// listening for that side; long-press 1 second enters the
    /// bidirectional continuous session (21:51: dual is two-way); in
    /// continuous mode tap pauses / resumes the shared session and
    /// long-press exits it. (A plain Button cannot take a long-press,
    /// so this is a label with tap + long-press gestures; the
    /// disabled look is an opacity, and the tap does nothing.)
    /// 2026-11-27: long-press only enters the not-started state
    /// (label "开始", light green); tap there starts the session,
    /// tap while started pauses / resumes it.
    private func dualMicButton(side: FaceSide) -> some View {
        let listening = listeningSide == side
        let labelText: String = {
            if isContinuousMode {
                // 2026-11-27: not started yet — tap starts.
                if !isContinuousStarted { return "开始" }
                return isContinuousPaused ? "继续" : "暂停"
            }
            if listening { return "正在听…" }
            return side == .me ? "我说" : "对方说话"
        }()
        let buttonColor: Color = {
            if isContinuousMode { return isContinuousStarted ? Color.green : Color.green.opacity(0.3) }
            if listening { return Color.green }
            return Color.accentColor
        }()
        let busyElsewhere = isWorking || (listeningSide != nil && listeningSide != side)
        return Label(labelText, systemImage: "mic")
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(buttonColor, in: Capsule())
            .foregroundStyle(isContinuousMode && !isContinuousStarted ? Color.green : Color.white)
            .opacity(busyElsewhere && !isContinuousMode ? 0.5 : 1)
            .onTapGesture {
                if isContinuousMode {
                    // 2026-11-27: tap in the not-started state
                    // starts the session; tap while started
                    // pauses / resumes it.
                    if isContinuousStarted {
                        toggleContinuousPause()
                    } else {
                        Task { await startContinuousSession() }
                    }
                } else if listening {
                    toggleTask = Task { await stopListening() }
                } else if !busyElsewhere {
                    toggleTask = Task { await toggleListening(side: side) }
                }
            }
            .onLongPressGesture(minimumDuration: 1.0) {
                if isContinuousMode {
                    Task { await stopContinuousMode() }
                } else if !busyElsewhere {
                    Task { await startContinuousMode() }
                }
            }
            .accessibilityLabel(side == .me ? "我的麦克风" : "对方麦克风")
            .accessibilityAddTraits(.isButton)
    }

    /// Item 9 (21:51): a small sound-wave animation while the
    /// continuous session is live; frozen low bars while paused.
    /// 2026-11-27: nothing is live before the session starts,
    /// so no waveform at all there; once started it animates,
    /// and freezes while paused.
    private var continuousWaveform: some View {
        Group {
            if isContinuousStarted {
                if isContinuousPaused {
                    HStack(spacing: 3) {
                        ForEach(0..<5) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green.opacity(0.5))
                                .frame(width: 3, height: 8)
                        }
                    }
                    .frame(height: 28)
                } else {
                    WaveformView()
                }
            }
        }
    }

    /// Item 8: the single-mode mic. Tap starts / stops (21:58);
    /// long-press 1 second enters / exits continuous mode (21:54,
    /// 22:59); in continuous mode tap pauses / resumes. Tap and
    /// long-press are exclusive gestures — a quick tap never fires
    /// the long-press, and a 1-second hold never fires the tap.
    /// 2026-11-27: long-press enters the not-started state (mic
    /// icon, light green, no time); tap there starts the session.
    private var singleMicButton: some View {
        Group {
            if isContinuousMode {
                // 2026-11-27: not started yet — the mic icon on
                // light green, no time (nothing has started, so
                // there is no elapsed time to show). Tap starts.
                // Once started, the icon becomes the elapsed
                // time, digits only (23:49).
                Group {
                    if !isContinuousStarted {
                        Image(systemName: "mic.fill")
                            .font(.title2)
                    } else {
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
                    }
                }
                .frame(width: 96, height: 96)
                .background(isContinuousStarted ? Color.green : Color.green.opacity(0.3), in: Circle())
                .foregroundStyle(isContinuousStarted ? Color.white : Color.green)
            } else {
                Image(systemName: listeningSide != nil ? "stop.fill" : "mic.fill")
                    .font(.title2)
                    .frame(width: 72, height: 72)
                    .background(micButtonColor, in: Circle())
                    .foregroundStyle(micIconColor)
            }
        }
        // Item 10 (22:44): the quota ring around the mic button.
        .overlay(quotaRing(diameter: isContinuousMode ? 106 : 82))
        .onTapGesture {
            if isContinuousMode {
                // 2026-11-27: tap in the not-started state
                // starts the session; tap while started
                // pauses / resumes it.
                if isContinuousStarted {
                    toggleContinuousPause()
                } else {
                    Task { await startContinuousSession() }
                }
            } else if !isWorking {
                toggleTask = Task { await toggleSingleListening() }
            }
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            if isContinuousMode {
                Task { await stopContinuousMode() }
            } else {
                Task { await startContinuousMode() }
            }
        }
        .accessibilityLabel(singleMicLabel)
        .accessibilityAddTraits(.isButton)
    }

    /// Item 10 (22:44): the quota ring around the mic button. The
    /// live-interpretation allowance is 20 sessions/day; the ring
    /// shows the fraction still free. Green while plenty, orange
    /// once the warning line is hit (16 used), grey at 0 — and at 0
    /// the button cannot enter continuous mode at all.
    private var quotaRemaining: Int { interpretEngine.quota.liveSessionsRemaining }
    private var quotaExhausted: Bool { quotaRemaining <= 0 }
    private var quotaFraction: Double {
        Double(quotaRemaining) / Double(InterpretationQuotaStore.liveSessionsFreePerDay)
    }
    private var quotaColor: Color {
        if quotaExhausted { return .gray }
        if interpretEngine.quota.liveSessionsWarning { return .orange }
        return .green
    }
    private func quotaRing(diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: quotaFraction)
                .stroke(quotaColor, lineWidth: 4)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// Item 10 (23:49): the consumption number at the top-left
    /// during a continuous session — today's live minutes so far,
    /// including the running session. There is no per-minute price
    /// for the live service anywhere in the codebase (free trial,
    /// no rate), so no ¥ figure can be computed honestly; minutes
    /// are the live usage number available. One decimal, no label.
    private var consumptionText: String {
        let total = interpretEngine.quota.liveMinutesToday + continuousElapsed / 60.0
        return String(format: "%.1f", total)
    }

    /// Item 9 (21:51): the mic button shows whether it is in use —
    /// grey when idle, green while listening or in continuous mode.
    /// Item 10: at 0 free sessions left the button goes a darker
    /// grey and cannot enter continuous mode (the one-shot tap
    /// still works — it does not use a live session).
    private var micButtonColor: Color {
        if quotaExhausted { return Color(.systemGray3) }
        return listeningSide != nil ? .green : Color(.systemGray5)
    }

    private var micIconColor: Color {
        if quotaExhausted { return .secondary }
        return listeningSide != nil ? .white : .primary
    }

    private var singleMicLabel: String {
        if isContinuousMode {
            if !isContinuousStarted { return "开始连续对话" }
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

    /// Item 9: long-press (1s) enters continuous mode (21:54, 22:59)
    /// on the interpretation engine (21:42: continuous mode IS
    /// interpretation). Single mode is one-way, face-to-face is
    /// two-way (21:51): the single user speaks Chinese to English
    /// (the only target language today, 21:33); two people get both
    /// directions, switched by auto-detected language.
    /// 2026-11-27: long-press only enters the "not started"
    /// state — no ticker, no engine, no billing yet, so a stray
    /// long-press burns no session. Tap starts the session
    /// (see startContinuousSession).
    @MainActor
    private func startContinuousMode() async {
        guard !isContinuousMode, !isWorking, listeningSide == nil else { return }
        guard let config else {
            errorMessage = "语音未配置。"
            return
        }
        // Item 10 (22:44): no free live sessions left today — the
        // button is grey and long-press does nothing.
        guard !quotaExhausted else {
            errorMessage = "今日免费同传次数已用完。"
            return
        }
        micHaptic(.medium)
        errorMessage = nil
        // Item 11: entering continuous mode supersedes a pending
        // transcript (the engine translates live from here).
        pendingTranscript = nil
        pendingSide = nil
        isContinuousMode = true
        isContinuousPaused = false
        isContinuousStarted = false
        continuousElapsed = 0
    }

    /// 2026-11-27: tap in the not-started state starts the live
    /// session — the ticker, the engine and the billing clock
    /// all begin here, not on the long-press entry.
    @MainActor
    private func startContinuousSession() async {
        guard isContinuousMode, !isContinuousStarted else { return }
        guard let config else {
            errorMessage = "语音未配置。"
            return
        }
        micHaptic(.medium)
        errorMessage = nil
        isContinuousStarted = true
        continuousElapsed = 0
        startContinuousTicker()
        // 2026-11-27 (息屏后台续跑，最小版): the screen is
        // allowed to lock now — the session keeps running in
        // the background on UIBackgroundModes audio (declared
        // in project.yml info.properties, verified present in
        // the shipped IPA) with the recorder engine running
        // for the whole session. Do NOT disable the idle timer
        // here: the old M11 line is what kept the screen
        // awake for the whole session. Leaving the page still
        // ends the session (N6, onDisappear) — locking or
        // backgrounding is not leaving the page.
        await startInterpretEngine(config: config)
    }

    /// Item 9: the engine wiring, mirrored from the interpretation
    /// page — same translator (DeepSeek / Qwen-MT fallback), same
    /// speaker order (my voice, then streaming TTS, then async MP3).
    @MainActor
    private func startInterpretEngine(config: VolcanoVoiceConfig) async {
        let glossary = GlossaryAST.glossaryList(from: glossaryEntries)
        let translator: InterpretationEngine.Translator = { text, source, target, note in
            let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
            let profile = request.profile
            let apiKey = request.apiKey
            let template = request.template
            let targetLanguage = target == .en ? "English" : "中文"
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            let results = try await TranslationPipeline().translate(
                segments: [text],
                profile: profile,
                apiKey: apiKey,
                targetLanguage: targetLanguage,
                template: template,
                glossary: glossaryEntries,
                customInstruction: note,
                tone: SettingsStore().translationTone,
                fallbackProfile: fallback?.profile,
                fallbackAPIKey: fallback?.apiKey
            ) { _, _ in }
            return results.first?.translation ?? ""
        }
        let speaker: InterpretationEngine.Speaker = { text in
            // Item 11: 播放翻译 off — subtitles only, no audio.
            // The setting is read live per segment, so toggling it
            // mid-session takes effect at once. Empty Data decodes
            // to nothing (EarphoneRouter guards), so the session
            // flows on.
            guard SettingsStore().conversationPlayTranslation else { return Data() }
            if await MyVoice.isEnabled(),
               let apiKey = await DashScopeStore.loadKey(),
               let voiceID = await QwenVoiceStore.loadVoiceID() {
                let settings = VoiceSettings()
                let workspaceID = await DashScopeStore.loadWorkspaceID()
                return try await QwenVoiceClone.synthesize(apiKey: apiKey, workspaceID: workspaceID, text: text, voiceID: voiceID, rate: settings.speechRate)
            }
            let settings = VoiceSettings()
            return try await VolcanoTTSClient(config: config).synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate)
        }
        // Streaming TTS for the sequential line (清单 12), same as
        // the interpretation page. Skipped when "my voice" is on:
        // the cloned voice has no streaming path here.
        // Item 11: also skipped when 播放翻译 is off at session
        // start — no point holding a streaming connection for
        // audio that will not play.
        var streamingSpeaker: InterpretationEngine.StreamingSpeaker?
        if SettingsStore().conversationPlayTranslation, await MyVoice.isEnabled() == false {
            let streamingClient = VolcanoStreamingTTSClient(config: config)
            do {
                try await streamingClient.connect()
                try streamingPlayer.start()
                self.continuousStreamingClient = streamingClient
                streamingSpeaker = { [streamingPlayer] text in
                    // Item 11: turned off mid-session — stay silent.
                    guard SettingsStore().conversationPlayTranslation else { return }
                    let settings = VoiceSettings()
                    try await streamingClient.synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate) { pcm in
                        streamingPlayer.enqueue(pcm)
                    }
                }
            } catch {
                self.continuousStreamingClient = nil
            }
        }
        await interpretEngine.start(
            // Item 11: 检测语言 off — always one-way 中文→英语,
            // even face-to-face (no auto-detected direction).
            direction: detectLanguageEnabled ? (isSingleMode ? .zhToEn : .both) : .zhToEn,
            config: config,
            glossary: glossary,
            translator: translator,
            speaker: speaker,
            streamingSpeaker: streamingSpeaker
        )
    }

    /// Item 9: long-press again stops continuous mode (21:51: pressing
    /// the continuous-mode button again is the end). The flags drop
    /// first so a second call hits the guard instead of persisting
    /// the session twice.
    /// 2026-11-27: also safe from the not-started state — the
    /// engine's stop() on an idle engine returns an empty record
    /// (no turns, no history, no quota), and the streaming
    /// client is nil there, so the disconnect is skipped.
    @MainActor
    private func stopContinuousMode() async {
        guard isContinuousMode else { return }
        isContinuousMode = false
        isContinuousPaused = false
        isContinuousStarted = false
        continuousElapsed = 0
        stopContinuousTicker()
        let record = await interpretEngine.stop()
        streamingPlayer.stop()
        if let client = continuousStreamingClient {
            continuousStreamingClient = nil
            await client.disconnect()
        }
        // 2026-11-27 (息屏后台续跑): no idle-timer reset here —
        // startContinuousSession no longer disables it, so there
        // is nothing to restore.
        // Keep the session visible in the conversation list after
        // exit: the engine's segments become turns (a zh→en segment
        // is mine speaking, an en→zh segment is the other person).
        for segment in record.segments where !segment.sourceText.isEmpty || !segment.translationText.isEmpty {
            turns.append(FaceTurn(
                speaker: segment.direction == .zhToEn ? .me : .them,
                source: segment.sourceText,
                translation: segment.translationText
            ))
        }
        // 22:02: the session content goes into history（最近项目）。
        if !record.segments.isEmpty {
            modelContext.insert(InterpretationSession(record: record))
            for segment in record.segments {
                guard !segment.sourceText.isEmpty, !segment.translationText.isEmpty else { continue }
                modelContext.insert(TransformHistory(
                    sourceExcerpt: TextExcerpt.make(segment.sourceText),
                    resultExcerpt: TextExcerpt.make(segment.translationText),
                    providerName: "连续对话",
                    model: "同传",
                    action: .translate,
                    targetLanguage: segment.direction == .zhToEn ? "English" : "中文",
                    status: "success"
                ))
            }
            try? modelContext.save()
        }
    }

    /// Item 9: tap in continuous mode pauses / resumes (21:54).
    /// The engine keeps the finished content (21:58: pause keeps
    /// what came before) and rebuilds the socket on resume if it
    /// went stale; the one-shot loop is not involved any more.
    /// 2026-11-27: only once the session has started — tap in
    /// the not-started state starts it instead.
    @MainActor
    private func toggleContinuousPause() {
        guard isContinuousMode, isContinuousStarted else { return }
        micHaptic(.light)
        if isContinuousPaused {
            isContinuousPaused = false
            startContinuousTicker()
            Task { await interpretEngine.resume() }
        } else {
            isContinuousPaused = true
            stopContinuousTicker()
            interpretEngine.pause()
        }
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
        // Item 11: a new listen supersedes a pending transcript.
        pendingTranscript = nil
        pendingSide = nil
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
            // Item 11: 自动翻译 off — the transcript waits for a
            // manual 翻译 tap instead of translating at once.
            if autoTranslateEnabled {
                try await translateAndSpeak(finalText, side: side)
            } else {
                pendingTranscript = finalText
                pendingSide = side
            }
        } catch is CancellationError {
            // S24: cancelled via 取消 — the finished turn stays in
            // the list, no error message.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Item 11: translate a pending transcript (自动翻译 off) when
    /// the user taps 翻译. Clears the pending row only on success,
    /// so a failed translation can be retried.
    @MainActor
    private func translatePending() async {
        guard let text = pendingTranscript, let side = pendingSide, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await translateAndSpeak(text, side: side)
            pendingTranscript = nil
            pendingSide = nil
        } catch is CancellationError {
            // S24: cancelled via 取消 — the turn stays pending.
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
        // Item 11: 检测语言 off — fixed 中文→英语 instead of
        // detecting the input language per turn.
        let target = detectLanguageEnabled ? TextLanguage.detect(text).translationTarget : "English"
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
        // Item 11: 播放翻译 off — the turn shows as text only;
        // 重播 still plays it on demand.
        if playTranslationEnabled {
            await speak(translation)
        }
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

/// Item 9 (21:51): a small sound-wave animation — five bars swaying
/// between two heights while a continuous session is live.
private struct WaveformView: View {
    @State private var phase = false

    private let upHeights: [CGFloat] = [10, 20, 28, 20, 10]
    private let downHeights: [CGFloat] = [20, 10, 14, 10, 20]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green)
                    .frame(width: 3, height: phase ? upHeights[i] : downHeights[i])
            }
        }
        .frame(height: 28)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                phase.toggle()
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

/// Item 11 (UI redesign, 22:51): the language card for the
/// conversation page — the same three toggles as the translate
/// page's card (item 5), but no settings row. The toggles are the
/// conversation page's own keys (conversation*), NOT the translate
/// page's shared ones — each card controls its own page.
private struct ConversationLanguageCard: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var playTranslationEnabled: Bool
    @Binding var autoTranslateEnabled: Bool
    @Binding var detectLanguageEnabled: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("语言") {
                    Toggle("播放翻译", isOn: $playTranslationEnabled)
                    Toggle("自动翻译", isOn: $autoTranslateEnabled)
                    Toggle("检测语言", isOn: $detectLanguageEnabled)
                }
            }
            .navigationTitle("语言选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
