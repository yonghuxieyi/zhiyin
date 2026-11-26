import AVFoundation
import RunseCore
import SwiftUI

/// "我的声音" (清单 8): record 10–30 s of your voice, clone it on
/// Alibaba Model Studio (Qwen-Audio 3.1), and use it for read-aloud.
/// The cloned voice id is stored in the keychain; the recording never
/// leaves the phone except for the one upload to DashScope.
///
/// Note: this has not been verified live yet — there is no DashScope
/// key. Server errors are shown verbatim.
struct MyVoiceView: View {
    @State private var voiceID: String?
    @State private var useMyVoice = VoiceSettings().useMyVoice
    @State private var workspaceID = ""
    @State private var hasDashScopeKey = false
    @State private var isRecording = false
    /// S18: starting takes an await (permission + session), and a
    /// second tap in that window used to start a second recorder
    /// and a second timer. Guard + button disable cover the window.
    @State private var isStartingRecording = false
    @State private var recordedSeconds = 0
    @State private var recordedURL: URL?
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var testAudio: Data?

    private let recorder = MyVoiceRecorder()
    private let player = AudioPlayer()

    var body: some View {
        Form {
            Section("状态") {
                HStack {
                    Text("固定音色")
                    Spacer()
                    Text(voiceID == nil ? "未创建" : "已创建")
                        .foregroundStyle(voiceID == nil ? .orange : .green)
                }
                if let voiceID {
                    Text(voiceID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle("用我的声音朗读", isOn: $useMyVoice)
                    .disabled(voiceID == nil)
                    .onChange(of: useMyVoice) { _, value in
                        var settings = VoiceSettings()
                        settings.useMyVoice = value
                    }
                if !hasDashScopeKey {
                    Text("先去设置 → Qwen-MT 备用里填 DashScope Key，复刻和合成都走它。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("业务空间 ID（可选）") {
                TextField("百炼业务空间 ID", text: $workspaceID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存业务空间 ID") {
                    Task {
                        do {
                            try await DashScopeStore.saveWorkspaceID(workspaceID.trimmingCharacters(in: .whitespacesAndNewlines))
                            statusMessage = "已保存到钥匙串。"
                            errorMessage = nil
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                .disabled(workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // S18: a mistyped workspace ID had no way back — add
                // a clear path (back to the default domain).
                Button("清除业务空间 ID", role: .destructive) {
                    Task {
                        do {
                            try await DashScopeStore.clearWorkspaceID()
                            workspaceID = ""
                            statusMessage = "业务空间 ID 已清除，改走默认域名。"
                            errorMessage = nil
                        } catch {
                            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                Text("在百炼控制台“业务空间详情”页查看。不填也能用，走旧域名。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("录音（10–30 秒）") {
                Text("找个安静地方，用平时说话的语气念一段中文，10 到 30 秒。录完点“创建音色”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        Label(isRecording ? "停止录音" : "开始录音", systemImage: isRecording ? "stop.circle" : "mic.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || isStartingRecording)
                    Spacer()
                    if isRecording || recordedSeconds > 0 {
                        Text("\(recordedSeconds) 秒")
                            .monospacedDigit()
                    }
                }
                if let recordedURL, !isRecording {
                    Text("已录 \(recordedSeconds) 秒")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("创建音色") {
                        Task { await createVoice(from: recordedURL) }
                    }
                    .disabled(isWorking || recordedSeconds < 10)
                    if recordedSeconds < 10 {
                        Text("至少录 10 秒再创建。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if voiceID != nil {
                Section("试听和删除") {
                    Button("试听我的声音") {
                        Task { await testVoice() }
                    }
                    .disabled(isWorking)
                    if let testAudio {
                        Button {
                            try? player.play(data: testAudio)
                        } label: {
                            Label("再播一次", systemImage: "speaker.wave.2")
                        }
                    }
                    Button("删除音色", role: .destructive) {
                        Task { await deleteVoice() }
                    }
                    .disabled(isWorking)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("我的声音")
        .task {
            voiceID = await QwenVoiceStore.loadVoiceID()
            hasDashScopeKey = await DashScopeStore.hasKey()
            workspaceID = await DashScopeStore.loadWorkspaceID() ?? ""
        }
    }

    @MainActor
    private func toggleRecording() async {
        if isRecording {
            recordedURL = recorder.stop()
            recordedSeconds = recorder.recordedSeconds
            isRecording = false
            return
        }
        // S18: one start at a time — the await below (permission +
        // session activation) used to admit a second recorder.
        guard !isStartingRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        errorMessage = nil
        statusMessage = nil
        testAudio = nil
        // S18: a previous recording's WAV is abandoned once a new
        // one starts — delete it instead of letting samples pile up
        // in tmp.
        if let oldURL = recordedURL {
            try? FileManager.default.removeItem(at: oldURL)
            recordedURL = nil
            recordedSeconds = 0
        }
        do {
            let ticks = try await recorder.start()
            recordedSeconds = 0
            recordedURL = nil
            isRecording = true
            Task {
                for await seconds in ticks {
                    recordedSeconds = seconds
                }
                // The tick stream also ends on the 30 s auto-stop, when
                // the recorder already stopped itself: finalize here, or
                // the recording would be lost (the view would still show
                // "recording" with no file to clone from).
                if isRecording {
                    recordedURL = recorder.stop()
                    recordedSeconds = recorder.recordedSeconds
                    isRecording = false
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func createVoice(from url: URL) async {
        guard let apiKey = await DashScopeStore.loadKey() else {
            errorMessage = "未配置 DashScope Key。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let audioData = try Data(contentsOf: url)
            let workspaceID = await DashScopeStore.loadWorkspaceID()
            let id = try await QwenVoiceClone.createVoice(apiKey: apiKey, workspaceID: workspaceID, audioData: audioData)
            try await QwenVoiceStore.saveVoiceID(id)
            voiceID = id
            statusMessage = "音色已创建。"
            // S18: the voice sample is uploaded — delete the local
            // WAV instead of letting samples pile up in tmp. Only
            // on success: a failure keeps the file for a retry.
            try? FileManager.default.removeItem(at: url)
            recordedURL = nil
            recordedSeconds = 0
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func testVoice() async {
        guard let apiKey = await DashScopeStore.loadKey(),
              let voiceID else {
            errorMessage = "未配置 DashScope Key 或音色。"
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let workspaceID = await DashScopeStore.loadWorkspaceID()
            let settings = VoiceSettings()
            let audio = try await QwenVoiceClone.synthesize(
                apiKey: apiKey,
                workspaceID: workspaceID,
                text: "你好，我是你的声音。",
                voiceID: voiceID,
                rate: settings.speechRate
            )
            testAudio = audio
            try player.play(data: audio)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func deleteVoice() async {
        guard let voiceID else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        // N11: without a DashScope Key the server-side voice cannot
        // be deleted — clearing the local record anyway would report
        // success while the voice stays alive in the DashScope
        // account (and eats one of its 10 voice slots), with the ID
        // forgotten so it can never be deleted later. Refuse instead.
        guard let apiKey = await DashScopeStore.loadKey() else {
            errorMessage = "没有 DashScope Key，删不掉阿里服务端的音色，本地记录也没删。请先在设置里填上 DashScope Key 再删除。"
            return
        }
        do {
            let workspaceID = await DashScopeStore.loadWorkspaceID()
            try await QwenVoiceClone.deleteVoice(apiKey: apiKey, workspaceID: workspaceID, voiceID: voiceID)
            try await QwenVoiceStore.clearVoiceID()
            self.voiceID = nil
            var settings = VoiceSettings()
            settings.useMyVoice = false
            useMyVoice = false
            testAudio = nil
            statusMessage = "音色已删除。"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Records 16 kHz mono WAV for voice cloning. WAV is written directly
/// so the file can be Base64-encoded and sent to DashScope as-is.
/// Elapsed seconds come back as an AsyncStream: a plain escaping
/// closure would have to capture the view's @State, which Swift 6
/// rejects when the closure crosses to this nonisolated recorder.
private final class MyVoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var seconds = 0
    private var tickContinuation: AsyncStream<Int>.Continuation?
    /// Last recording URL, kept after stop() so a second stop() call
    /// (e.g. the view finalizing after the 30 s auto-stop) still
    /// returns the file instead of nil.
    private var lastURL: URL?

    var recordedSeconds: Int { seconds }

    func start() async throws -> AsyncStream<Int> {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            throw QwenVoiceError.notConfigured("麦克风权限")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myvoice-\(UUID().uuidString).wav")
        lastURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        self.recorder = recorder
        seconds = 0
        // S18: record() returns false when the recorder cannot start
        // (no input, broken session) — the old code ignored it and
        // the timer ran anyway, sending an empty/broken WAV to the
        // clone call 30 s later.
        guard recorder.record() else {
            self.recorder = nil
            throw QwenVoiceError.recordingFailed("无输入或音频会话异常")
        }
        let stream = AsyncStream<Int> { continuation in
            self.tickContinuation = continuation
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.seconds += 1
                self.tickContinuation?.yield(self.seconds)
                if self.seconds >= 30 {
                    _ = self.stop()
                }
            }
        }
        return stream
    }

    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        tickContinuation?.finish()
        tickContinuation = nil
        let url = lastURL ?? recorder?.url
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        return url
    }
}
