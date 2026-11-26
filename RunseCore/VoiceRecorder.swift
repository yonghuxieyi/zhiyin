import AVFoundation
import Foundation

/// Captures microphone audio as 16 kHz mono 16-bit PCM chunks for the
/// streaming ASR client. The tap callback runs on a realtime thread, so
/// chunks are handed out through an `AsyncStream` continuation, which is
/// thread-safe, instead of touching UI state directly.
public final class VoiceRecorder {
    public enum RecorderError: Error, LocalizedError {
        case noInputNode
        case cannotStart(Error)

        public var errorDescription: String? {
            switch self {
            case .noInputNode: "No microphone input is available."
            case .cannotStart(let error): "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Data>.Continuation?

    public init() {}

    /// Starts the audio session and the tap. Returns a stream of PCM
    /// chunks (16 kHz, mono, 16-bit, ~100 ms each). Call `stop` to end it.
    public func start() throws -> AsyncStream<Data> {
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
