import AVFoundation
import Foundation

/// Captures microphone audio as 16 kHz mono 16-bit PCM chunks for the
/// streaming ASR client. The tap callback runs on a realtime thread, so
/// chunks are handed out through an `AsyncStream` continuation, which is
/// thread-safe, instead of touching UI state directly.
/// N7 跟进修：start() 是非隔离 async 方法，从 @MainActor 的
/// InterpretationEngine（feed Task）和两个页面里 await 它时，
/// recorder 要跨隔离域发送；VoiceRecorder 不是 Sendable，
/// Swift 6 报 sending 'self.recorder' risks data races。
/// 标 @unchecked Sendable：同一时间只有一个持有者在用，
/// start/stop 由持有方串行发起；唯一跨线程的触碰是录音 tap
/// 回调，只通过线程安全的 AsyncStream continuation yield
/// 数据，converter 在装 tap、启动引擎前就已设好、tap 运行
/// 期间不再改；AVAudioEngine 的 start/stop 本身线程安全。
public final class VoiceRecorder: @unchecked Sendable {
    public enum RecorderError: Error, LocalizedError {
        case noInputNode
        case cannotStart(Error)
        /// N7: the mic permission was denied (or the user declined
        /// the prompt). Recording without it only produces silence,
        /// which used to surface as the misleading "没有识别到说话
        /// 内容" — as if the network or the service had failed.
        case micPermissionDenied

        public var errorDescription: String? {
            switch self {
            case .noInputNode: "No microphone input is available."
            case .cannotStart(let error): "Could not start recording: \(error.localizedDescription)"
            case .micPermissionDenied: "麦克风权限未开启：请在“设置 → 隐私与安全性 → 麦克风”里打开智音的权限，再重新开始。"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Data>.Continuation?

    public init() {}

    /// N6 backstop: if the recorder is dropped without `stop()`
    /// (owning engine dismissed mid-session), remove the tap and
    /// stop the engine instead of leaking the mic. A plain class's
    /// own deinit may touch its own members; the @MainActor engine's
    /// deinit cannot (Swift 6), so the cleanup lives here.
    deinit {
        stop()
    }

    /// N7: checks the mic permission before recording starts.
    /// `.granted` proceeds; `.undetermined` asks once; `.denied`
    /// throws `micPermissionDenied` instead of recording silence.
    /// All three callers (voice, face-to-face, interpretation) go
    /// through `start()`, so one gate covers them.
    public static func requireMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw RecorderError.micPermissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { throw RecorderError.micPermissionDenied }
        @unknown default:
            return
        }
    }

    /// Starts the audio session and the tap. Returns a stream of PCM
    /// chunks (16 kHz, mono, 16-bit, ~100 ms each). Call `stop` to end it.
    public func start() async throws -> AsyncStream<Data> {
        try await Self.requireMicrophonePermission()
        let session = AVAudioSession.sharedInstance()
        do {
            // M6: .allowBluetooth routes the mic through the HFP
            // phone-call profile, which is mono — the left/right pan
            // (-1/+1) of the earphone router would be lost, and
            // .measurement has no echo cancellation, so played
            // translation audio would be picked up and re-translated.
            // A2DP keeps stereo playback; the input is forced to the
            // iPhone's own microphone.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                // Best effort: the built-in mic is the default input
                // anyway, so a failure here must not block recording.
                try? session.setPreferredInput(builtInMic)
            }
            try session.setActive(true)
        } catch {
            throw RecorderError.cannotStart(error)
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw RecorderError.noInputNode
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, targetFormat: targetFormat)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.cannotStart(error)
        }
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 1024) else { return }
        var error: NSError?
        // M5: the converter's input callback may be invoked more than
        // once per convert call. Returning the same buffer every time
        // feeds the same audio twice (duplicated words / odd speed in
        // recognition). The first call supplies the buffer; later calls
        // report .noDataNow. EarphoneRouter.decodeMP3ToPCM24k already
        // uses this pattern.
        var supplied = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, converted.frameLength > 0,
              let channelData = converted.int16ChannelData else { return }
        let bytes = Data(bytes: channelData[0], count: Int(converted.frameLength) * 2)
        continuation?.yield(bytes)
    }
}
