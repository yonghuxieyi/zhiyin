import RunseCore
import SwiftData
import SwiftUI
import UIKit

/// Simultaneous interpretation: its own page. Live subtitles in both
/// languages side by side, pause / review / save, quota and latency
/// in plain sight. When the live path is down the page keeps working
/// on the sequential line and says so, with a retry button.
struct InterpretationView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]
    @Query(sort: \InterpretationSession.startedAt, order: .reverse) private var pastSessions: [InterpretationSession]

    @StateObject private var engine = InterpretationEngine()
    @State private var config: VolcanoVoiceConfig?
    @State private var configChecked = false
    @State private var direction: InterpretationEngine.Direction = .zhToEn
    @State private var selectedSession: InterpretationSession?
    @State private var streamingClient: VolcanoStreamingTTSClient?
    @State private var sequentialFirstAudioMs: Double?
    private let streamingPlayer = StreamingAudioPlayer()

    private var isRunning: Bool {
        engine.phase == .live || engine.phase == .fallback || engine.phase == .paused || engine.phase == .connecting
    }

    var body: some View {
        NavigationStack {
            List {
                if !configChecked {
                    Section { ProgressView("正在检查语音配置") }
                } else if config == nil {
                    Section("语音未配置") {
                        Text("同传走火山豆包语音。AppID 和 Access Token 在“语音”页填一次，只存手机钥匙串。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    controlSection
                    statusSection
                    quotaSection
                    latencySection
                    glossarySection
                    transcriptSection
                }

                if !pastSessions.isEmpty {
                    Section("往期同传") {
                        ForEach(pastSessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(session.startedAt, style: .date)
                                        Text(session.startedAt, style: .time)
                                        Spacer()
                                        Text(session.directionTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(session.segments.count) 句 · \(session.modeTitle) · \(Int(session.durationSeconds))秒")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                modelContext.delete(pastSessions[offset])
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("同传")
            .task {
                config = await VolcanoVoiceStore.load()
                configChecked = true
                engine.refreshQuota()
            }
            .sheet(item: $selectedSession) { session in
                InterpretationSessionDetailView(session: session)
            }
            .onDisappear {
                // N6: leaving the page must end the session, or the
                // mic / live sockets keep running and the screen
                // never locks again (isIdleTimerDisabled stays on).
                if isRunning {
                    Task { await stopSession() }
                }
            }
        }
    }

    // MARK: - Controls

    private var controlSection: some View {
        Section("同传") {
            Picker("方向", selection: $direction) {
                ForEach(InterpretationEngine.Direction.allCases, id: \.self) { dir in
                    Text(dir.title).tag(dir)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)

            HStack {
                if !isRunning {
                    Button {
                        Task { await startSession() }
                    } label: {
                        Label("开始同传", systemImage: "mic")
                    }
                    .buttonStyle(.borderedProminent)
                } else if engine.isPaused {
                    Button {
                        Task { await engine.resume() }
                    } label: {
                        Label("继续", systemImage: "play")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        engine.pause()
                    } label: {
                        Label("暂停", systemImage: "pause")
                    }
                    .buttonStyle(.bordered)
                }

                if isRunning {
                    Button {
                        Task { await stopSession() }
                    } label: {
                        Label("结束并保存", systemImage: "stop")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if direction == .both && isRunning {
                Picker("锁定方向", selection: Binding(
                    get: { engine.lockedDirection },
                    set: { newValue in Task { await engine.lockDirection(newValue) } }
                )) {
                    Text("自动").tag(nil as InterpretationEngine.Direction?)
                    Text("中文 → 英文").tag(InterpretationEngine.Direction.zhToEn as InterpretationEngine.Direction?)
                    Text("英文 → 中文").tag(InterpretationEngine.Direction.enToZh as InterpretationEngine.Direction?)
                }
                .pickerStyle(.segmented)
            }

            Text("左耳原声，右耳译音。说一句话就翻一句；对方说错了自己纠正重说，能跟上改过来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("状态") {
            HStack {
                Text("模式")
                Spacer()
                Text(modeTitle)
                    .foregroundStyle(engine.mode == .live ? .green : .orange)
            }

            if engine.grantPending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("同声传译还没开通")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("火山语音控制台 → 语音技术 → 应用管理 → Zhiyin 应用 → 接入能力，勾上“豆包同声传译大模型”，保存后回来点“切回实时同传”。现在先用顺序语音线，功能不受影响。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if engine.mode == .fallback, let reason = engine.fallbackReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已退回顺序语音线")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("原因：\(reason)。识别 → 翻译 → 合成照常进行，不会卡死；30 秒后自动试一次切回，失败就留在这条线上。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("切回实时同传") {
                        Task { await engine.retryLive() }
                    }
                }
            }

            if let errorMessage = engine.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                // N7: denied mic permission gets a one-tap way to
                // Settings instead of just a message.
                if errorMessage.hasPrefix("麦克风权限未开启") {
                    Button("去设置打开麦克风权限") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.footnote)
                }
            }

            // S10: stopping takes a while (disconnects + tail
            // translation) — show the step instead of a frozen UI.
            if engine.isStopping {
                HStack {
                    ProgressView()
                    Text(engine.stopProgress ?? "正在结束会话…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeTitle: String {
        switch engine.phase {
        case .idle: "未开始"
        case .connecting: "连接中…"
        case .live: "实时同传"
        case .fallback: "顺序语音线"
        case .paused: "已暂停"
        case .stopped: "已结束"
        case .error: "出错"
        }
    }

    // MARK: - Quota

    /// S12: "yyyy-MM-dd" for the balance-as-of date.
    private static func balanceDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var quotaSection: some View {
        Section("额度") {
            liveSessionsRow
            liveMinutesRow
            asrRemainingRow
            ttsRemainingRow
            balanceRow
            Text("识别 20 小时、合成 20000 字试用到 2027-05-25；超量按量后付费，余额不足会停。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// S12: each quota row is its own view so the compiler type-checks
    /// them one at a time — the whole Section in one expression was
    /// too much for it ("unable to type-check in reasonable time").
    private var liveSessionsRow: some View {
        let quota = engine.quota
        return HStack {
            Text("今日同传")
            Spacer()
            Text("\(quota.liveSessionsToday)/\(InterpretationQuotaStore.liveSessionsFreePerDay) 次")
                .foregroundStyle(quota.liveSessionsWarning ? .orange : .primary)
        }
    }

    private var liveMinutesRow: some View {
        let quota = engine.quota
        return HStack {
            Text("今日同传用时")
            Spacer()
            Text(String(format: "%.1f 分钟", quota.liveMinutesToday))
                .foregroundStyle(.secondary)
        }
    }

    private var asrRemainingRow: some View {
        let quota = engine.quota
        return HStack {
            Text("识别试用剩")
            Spacer()
            Text(String(format: "%.1f 小时", quota.asrMinutesRemaining / 60.0))
                .foregroundStyle(quota.asrWarning ? .orange : .secondary)
        }
    }

    private var ttsRemainingRow: some View {
        let quota = engine.quota
        return HStack {
            Text("合成试用剩")
            Spacer()
            Text("\(quota.ttsCharsRemaining) 字")
                .foregroundStyle(quota.ttsWarning ? .orange : .secondary)
        }
    }

    private var balanceRow: some View {
        let quota = engine.quota
        return HStack {
            Text("账户余额")
            Spacer()
            // S12: there is no console API to query the balance,
            // so a missing value must read as unknown — the old
            // hardcoded "¥2.36（2026-11-25 记录）" looked like a
            // live figure and only got staler. The value can be
            // updated by hand in Settings.
            if let balance = quota.balanceYuan {
                Text(balanceDisplayText(balance: balance, asOf: quota.balanceAsOf))
                    .foregroundStyle(balance < 5 ? .orange : .secondary)
            } else {
                Text("未知（2026-11-25 最后一次记录 ¥2.36）")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// S12: balance string built outside the view builder — the nested
    /// map + concatenation inside the Section was part of what the
    /// type-checker choked on.
    private func balanceDisplayText(balance: Double, asOf: Date?) -> String {
        var text = "¥" + String(format: "%.2f", balance)
        if let asOf { text += "（截至 " + Self.balanceDateString(asOf) + "）" }
        return text
    }

    // MARK: - Latency

    private var latencySection: some View {
        Section("延迟") {
            HStack {
                Text("目标 / 上限")
                Spacer()
                Text("2.5 秒 / 3 秒")
                    .foregroundStyle(.secondary)
            }
            if let latency = engine.latency {
                if let firstText = latency.firstTranslationTextMs {
                    HStack {
                        Text("首句译文")
                        Spacer()
                        Text(String(format: "%.0f 毫秒", firstText))
                            .foregroundStyle(firstText <= LatencyBudget.targetMs ? .green : .orange)
                    }
                }
                if let firstAudio = latency.firstTTSAudioMs {
                    HStack {
                        Text("首句语音")
                        Spacer()
                        Text(String(format: "%.0f 毫秒", firstAudio))
                            .foregroundStyle(firstAudio <= LatencyBudget.limitMs ? .green : .orange)
                    }
                }
            } else {
                Text("还没实测数字：服务端 S2S 标称 2.53 秒（文档值），加播放缓冲后合计约 2.63 秒，在 3 秒上限内、略高于 2.5 秒目标；第一句出来后这里显示实测值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let sequentialFirstAudioMs {
                HStack {
                    Text("顺序线首句语音（流式）")
                    Spacer()
                    Text(String(format: "%.0f 毫秒", sequentialFirstAudioMs))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Glossary

    private var glossarySection: some View {
        Section("术语表") {
            let filled = glossaryEntries.filter { !$0.targetTranslation.isEmpty }.count
            HStack {
                Text("术语")
                Spacer()
                Text("\(filled) 个已填译法 / 共 \(glossaryEntries.count) 个")
                    .foregroundStyle(.secondary)
            }
            Text("直播同传里术语表只能提示模型、不保证每个词都按表翻；强制保证只在顺序线做得到（缺词会重新问一遍）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        Section("对照") {
            if engine.segments.isEmpty && engine.liveDraftSource.isEmpty && engine.liveDraftTranslation.isEmpty {
                Text("开始后原文和译文对照着出现在这里；能暂停、能回看，结束后存下来。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.segments) { segment in
                VStack(alignment: .leading, spacing: 6) {
                    if segment.speakerChanged {
                        Label("换人", systemImage: "person.2")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if !segment.sourceText.isEmpty {
                        Text(segment.sourceText)
                            .font(.body)
                    }
                    if !segment.translationText.isEmpty {
                        Text(segment.translationText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(segment.mode == .live ? "实时" : "顺序")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(segment.mode == .live ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                        if let latencyMs = segment.latencyMs {
                            // Latency here is the translation delay: source
                            // sentence started → first translation text.
                            Text(String(format: "译文延迟 %.0f 毫秒", latencyMs))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if !engine.liveDraftSource.isEmpty || !engine.liveDraftTranslation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !engine.liveDraftSource.isEmpty {
                        Text(engine.liveDraftSource)
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.6))
                    }
                    if !engine.liveDraftTranslation.isEmpty {
                        Text(engine.liveDraftTranslation)
                            .font(.body)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startSession() async {
        guard let config else { return }
        // M11: keep the screen awake for the whole session — a
        // 30–60 minute interpretation must not be cut off by the
        // idle timer. Restored in stopSession.
        UIApplication.shared.isIdleTimerDisabled = true
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
            // `config` is already unwrapped by the guard at the top of
            // startSession; the closure just captures it. "My voice"
            // (cloned Qwen voice) wins when it is switched on; otherwise
            // the picked Doubao voice (speaker + rate) from the 语音 tab.
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
        // Streaming TTS for the sequential line (清单 12): one
        // connection for the whole session, audio plays as it arrives
        // instead of waiting ~9 s for a finished MP3. If the
        // connection fails, the engine falls back to `speaker` above.
        // Skipped when "my voice" is on: the cloned voice is a
        // different service (Qwen) and has no streaming path here.
        sequentialFirstAudioMs = nil
        var streamingSpeaker: InterpretationEngine.StreamingSpeaker?
        if await MyVoice.isEnabled() == false {
            let streamingClient = VolcanoStreamingTTSClient(config: config)
            do {
                try await streamingClient.connect()
                try streamingPlayer.start()
                self.streamingClient = streamingClient
                streamingSpeaker = { [streamingPlayer] text in
                    let settings = VoiceSettings()
                    try await streamingClient.synthesize(text: text, speaker: settings.speakerID, speechRate: settings.speechRate) { pcm in
                        streamingPlayer.enqueue(pcm)
                    }
                    if sequentialFirstAudioMs == nil,
                       let ms = await streamingClient.lastFirstAudioLatencyMs {
                        sequentialFirstAudioMs = ms
                    }
                }
            } catch {
                self.streamingClient = nil
            }
        }
        await engine.start(
            direction: direction,
            config: config,
            glossary: glossary,
            translator: translator,
            speaker: speaker,
            streamingSpeaker: streamingSpeaker
        )
    }

    private func stopSession() async {
        UIApplication.shared.isIdleTimerDisabled = false
        let record = await engine.stop()
        streamingPlayer.stop()
        if let client = streamingClient {
            streamingClient = nil
            await client.disconnect()
        }
        guard !record.segments.isEmpty else { return }
        modelContext.insert(InterpretationSession(record: record))
        try? modelContext.save()
    }
}

struct InterpretationSessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let session: InterpretationSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("方向")
                        Spacer()
                        Text(session.directionTitle).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("模式")
                        Spacer()
                        Text(session.modeTitle).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("时长")
                        Spacer()
                        Text("\(Int(session.durationSeconds)) 秒").foregroundStyle(.secondary)
                    }
                    if let latencyMs = session.latencyMs {
                        HStack {
                            Text("首句语音延迟")
                            Spacer()
                            Text(String(format: "%.0f 毫秒", latencyMs)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("对照") {
                    ForEach(session.segments.sorted(by: { $0.createdAt < $1.createdAt })) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            if segment.speakerChanged {
                                Label("换人", systemImage: "person.2")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if !segment.sourceText.isEmpty {
                                Text(segment.sourceText)
                            }
                            if !segment.translationText.isEmpty {
                                Text(segment.translationText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("\(session.startedAt, style: .date)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: session.exportedText()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
