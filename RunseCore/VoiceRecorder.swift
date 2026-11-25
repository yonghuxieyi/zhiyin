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
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
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
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, converted.frameLength > 0,
              let channelData = converted.int16ChannelData else { return }
        let bytes = Data(bytes: channelData[0], count: Int(converted.frameLength) * 2)
        continuation?.yield(bytes)
    }
}
