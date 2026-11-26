import AVFoundation
import Foundation

/// Stereo earphone routing for interpretation: the original voice
/// goes to the left ear, the translation to the right ear (boss's
/// bar). Two AVAudioPlayerNodes with pan -1 / +1 feed the main
/// mixer; the engine converts the 16kHz / 24kHz mono inputs to the
/// hardware output format.
///
/// The live path feeds PCM chunks directly (original 16kHz mono,
/// translation 24kHz mono PCM from the service). The fallback path
/// decodes the async TTS MP3 to 24kHz mono PCM first.
///
/// Assumes the audio session is already configured for
/// play-and-record with Bluetooth A2DP and the built-in microphone
/// (VoiceRecorder owns that; M6); this class only manages the engine.
/// Device-only: no unit tests cover the engine itself, only the
/// format constants.
public final class EarphoneRouter {
    /// Original voice: left ear.
    public static let originalPan: Float = -1
    /// Translation: right ear.
    public static let translationPan: Float = 1

    public static let originalSampleRate: Double = 16000
    public static let translationSampleRate: Double = 24000

    private let engine = AVAudioEngine()
    private let originalNode = AVAudioPlayerNode()
    private let translationNode = AVAudioPlayerNode()
    private var started = false
    private var observers: [NSObjectProtocol] = []

    public init() {
        engine.attach(originalNode)
        engine.attach(translationNode)
        let originalFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.originalSampleRate, channels: 1, interleaved: true)
        let translationFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.translationSampleRate, channels: 1, interleaved: true)
        if let originalFormat {
            engine.connect(originalNode, to: engine.mainMixerNode, format: originalFormat)
            originalNode.pan = Self.originalPan
        }
        if let translationFormat {
            engine.connect(translationNode, to: engine.mainMixerNode, format: translationFormat)
            translationNode.pan = Self.translationPan
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func start() throws {
        guard !started else { return }
        try engine.start()
        originalNode.play()
        translationNode.play()
        started = true
        // AirPods disconnects / interruptions stop the engine; bring
        // it back so a long session survives them.
        //
        // Interruption handling is split by type: on `.began` (an
        // incoming call, Siri, an alarm) the system has already
        // stopped the engine — restarting here would fight it and
        // fail. On `.ended` with `.shouldResume`, the session must
        // be re-activated FIRST (the call deactivated it), and only
        // then can the engine start again.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, self.started else { return }
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                // The system owns the audio session now; do nothing.
                break
            case .ended:
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                guard options.contains(.shouldResume) else { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.engine.start()
                    self.originalNode.play()
                    self.translationNode.play()
                } catch {
                    // The next route-change notification will retry
                    // the restart; a failed start here is not fatal.
                }
            @unknown default:
                break
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            try? self.engine.start()
            self.originalNode.play()
            self.translationNode.play()
        })
    }

    public func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        originalNode.stop()
        translationNode.stop()
        engine.stop()
        started = false
    }

    public var isStarted: Bool { started }

    /// Plays one original-voice PCM chunk (16kHz 16-bit mono) on the
    /// left ear.
    public func playOriginal(pcm: Data) {
        guard started else { return }
        guard let buffer = Self.pcmBuffer(pcm, sampleRate: Self.originalSampleRate) else { return }
        originalNode.scheduleBuffer(buffer)
    }

    /// Plays one translation PCM chunk (24kHz 16-bit mono) on the
    /// right ear.
    public func playTranslation(pcm: Data) {
        guard started else { return }
        guard let buffer = Self.pcmBuffer(pcm, sampleRate: Self.translationSampleRate) else { return }
        translationNode.scheduleBuffer(buffer)
    }

    /// Decodes fallback TTS output (MP3) to 24kHz mono PCM and plays
    /// it on the right ear.
    public func playTranslationMP3(_ mp3: Data) {
        guard let pcm = Self.decodeMP3ToPCM24k(mp3) else { return }
        playTranslation(pcm: pcm)
    }

    /// Builds an AVAudioPCMBuffer from interleaved 16-bit PCM bytes.
    /// Pure format math, covered by unit tests.
    public static func pcmBuffer(_ pcm: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard pcm.count >= 2, pcm.count % 2 == 0 else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else { return nil }
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channel = buffer.int16ChannelData else { return nil }
        pcm.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            channel[0].assign(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        return buffer
    }

    /// Decodes MP3 data to interleaved 16-bit PCM at 24kHz mono.
    /// Returns nil on any decode failure.
    public static func decodeMP3ToPCM24k(_ mp3: Data) -> Data? {
        let url = FileManager.default.temporaryDirectory.appending(path: "zhiyin-tts-\(UUID().uuidString).mp3")
        do {
            try mp3.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: translationSampleRate, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else { return nil }
            let frameCount = AVAudioFrameCount(file.length)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else { return nil }
            try file.read(into: inputBuffer)
            let outputCapacity = AVAudioFrameCount(Double(frameCount) * translationSampleRate / file.processingFormat.sampleRate) + 1024
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return nil }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            guard status != .error, error == nil, let channel = outputBuffer.int16ChannelData else { return nil }
            return Data(bytes: channel[0], count: Int(outputBuffer.frameLength) * 2)
        } catch {
            return nil
        }
    }
}
