import AVFoundation
import ImageIO
import PhotosUI
import RunseCore
import SwiftData
import SwiftUI
import UIKit

/// Live camera translation (清单 10): point the camera at English text
/// and the Chinese translation appears on screen — no need to take a
/// photo first. Frames are OCR'd at most once every 2 seconds (Vision
/// on device), and the text is re-translated only when it changes.
///
/// Item 12 (UI redesign): full-screen camera, controls floating over
/// the picture — a language pair pill at the top, the translation
/// card and the shutter row at the bottom (photo picker left, big
/// shutter in the middle, torch right). The shutter freezes the
/// current frame (or a picked photo) and translates that still;
/// tap it again to go back to live.
struct LiveCameraView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]

    @StateObject private var camera = LiveCameraController()
    @State private var translation = ""
    @State private var lastTranslatedText = ""
    @State private var isTranslating = false
    /// N9: text that arrived while a translation was running. The
    /// old code dropped it, and a static camera never re-triggered,
    /// so the screen kept the old translation forever.
    @State private var pendingText = ""
    @State private var errorMessage: String?
    /// Item 12: the language pair at the top (Apple style, like the
    /// translate page's card). Auto follows the detected language.
    @State private var direction: TranslationDirection = .auto
    /// Item 12: a photo picked from the library, shown frozen.
    @State private var selectedPhoto: PhotosPickerItem?
    /// Item 12: the frozen still (shutter frame or picked photo).
    /// While set, live OCR results are ignored and the still's
    /// translation stays on screen; nil means live.
    @State private var stillImage: UIImage?
    /// Item 12: torch state, mirrored from the controller.
    @State private var torchOn = false

    private let pipeline = TranslationPipeline()

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
            // Item 12: the frozen still covers the live preview.
            if let stillImage {
                Image(uiImage: stillImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                languageBar
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    if !camera.recognizedText.isEmpty {
                        Text(camera.recognizedText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if isTranslating {
                        ProgressView("正在翻译…")
                    } else if !translation.isEmpty {
                        Text(translation)
                            .font(.title3)
                    } else if camera.recognizedText.isEmpty {
                        Text(stillImage == nil ? "把镜头对准要翻译的英文" : "这张图里没有认出文字")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                shutterRow
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("实时取景")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: camera.recognizedText) { _, text in
            // Item 12: while a still is frozen, live OCR results
            // must not overwrite the still's translation.
            guard stillImage == nil else { return }
            Task { await translateIfNeeded(text) }
        }
        .onChange(of: direction) { _, _ in
            // A new direction re-translates the text on screen.
            guard !camera.recognizedText.isEmpty else { return }
            lastTranslatedText = ""
            Task { await translateIfNeeded(camera.recognizedText) }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task { await loadPickedPhoto(item) }
        }
        .task {
            torchOn = false
            await camera.start()
        }
        .onDisappear {
            camera.stop()
        }
    }

    /// Item 12: the language pair at the top, floating over the
    /// camera (Apple style, compact — short names fit a top bar).
    private var languageBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("中文") { setSourceLanguage(.chinese) }
                Button("英语") { setSourceLanguage(.english) }
                Button("自动检测") { direction = .auto }
            } label: {
                HStack(spacing: 4) {
                    Text(shortName(currentPair.source))
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            }
            Button {
                swapDirection()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .accessibilityLabel("互换语种")
            Menu {
                Button("中文") { setTargetLanguage(.chinese) }
                Button("英语") { setTargetLanguage(.english) }
            } label: {
                HStack(spacing: 4) {
                    Text(shortName(currentPair.target))
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Item 12: photo picker left, big shutter middle, torch right —
    /// all floating over the camera, no background bar.
    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("从相册选图")
            Spacer()
            Button {
                shutterTapped()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(stillImage == nil ? .white : .green)
                        .frame(width: 58, height: 58)
                    if stillImage != nil {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                    }
                }
            }
            .accessibilityLabel(stillImage == nil ? "拍照" : "继续实时取景")
            Spacer()
            Button {
                torchOn = camera.toggleTorch()
            } label: {
                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.35), in: Circle())
                    .foregroundStyle(torchOn ? .yellow : .white)
            }
            .accessibilityLabel(torchOn ? "关闭闪光灯" : "打开闪光灯")
        }
    }

    /// Item 12: the pair shown at the top. An explicit direction
    /// wins; in auto mode the detected language of the text on
    /// screen decides (empty input defaults to 中文 → 英语).
    private var currentPair: (source: TextLanguage, target: TextLanguage) {
        pair(for: camera.recognizedText)
    }

    private func pair(for text: String) -> (source: TextLanguage, target: TextLanguage) {
        switch direction {
        case .toEnglish:
            // Bare tuple literals don't get the function's return type as
            // contextual type in an implicit switch-branch return, so the
            // enum cases must be fully qualified here.
            return (source: TextLanguage.chinese, target: TextLanguage.english)
        case .toChinese:
            return (source: TextLanguage.english, target: TextLanguage.chinese)
        case .auto:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (source: TextLanguage.chinese, target: TextLanguage.english)
            }
            let detected = TextLanguage.detect(text)
            return (source: detected, target: detected == TextLanguage.chinese ? TextLanguage.english : TextLanguage.chinese)
        }
    }

    private func shortName(_ language: TextLanguage) -> String {
        switch language {
        case .chinese: "中文"
        case .english: "英语"
        }
    }

    private func setSourceLanguage(_ language: TextLanguage) {
        direction = language == .chinese ? .toEnglish : .toChinese
    }

    private func setTargetLanguage(_ language: TextLanguage) {
        direction = language == .english ? .toEnglish : .toChinese
    }

    private func swapDirection() {
        direction = currentPair.source == .chinese ? .toChinese : .toEnglish
    }

    /// Item 12: the shutter freezes the current frame and translates
    /// that still; tap again to go back to live.
    @MainActor
    private func shutterTapped() {
        if stillImage != nil {
            stillImage = nil
            return
        }
        guard let frame = camera.latestFrame else { return }
        stillImage = UIImage(cgImage: frame.cgImage, scale: 1.0, orientation: Self.uiOrientation(from: frame.orientation))
        Task { await recognizeStill(frame.cgImage, orientation: frame.orientation) }
    }

    /// Item 12: a photo picked from the library is shown frozen and
    /// translated like a shutter still.
    @MainActor
    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                errorMessage = "读不到这张图。"
                return
            }
            stillImage = image
            await recognizeStill(cgImage, orientation: Self.cgOrientation(from: image.imageOrientation))
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Item 12: OCR + translate one still frame at once (bypassing
    /// the 2-second live throttle).
    @MainActor
    private func recognizeStill(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) async {
        errorMessage = nil
        do {
            let lines = try await VisionTextRecognizer.recognizeText(in: cgImage, orientation: orientation)
            let text = VisionTextRecognizer.plainText(from: lines)
            camera.setRecognizedText(text)
            await translateIfNeeded(text)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// CGImagePropertyOrientation → UIImage.Orientation, so a frozen
    /// camera frame displays upright.
    private static func uiOrientation(from cgOrientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch cgOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// UIImage.Orientation → CGImagePropertyOrientation, so Vision
    /// reads a picked photo upright. Mirrors PhotoView.cgOrientation.
    private static func cgOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    @MainActor
    private func translateIfNeeded(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastTranslatedText else { return }
        // N9: park text that arrives mid-translation instead of
        // dropping it; it is picked up below when this run finishes.
        if isTranslating {
            pendingText = trimmed
            return
        }
        lastTranslatedText = trimmed
        isTranslating = true
        errorMessage = nil
        do {
            let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
            let profile = request.profile
            let apiKey = request.apiKey
            let template = request.template
            let target = pair(for: trimmed).target.translationTarget
            let parts = TextSegmenter.segments(for: trimmed, maxChars: TextSegmenter.maxChars(for: profile))
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
            translation = results.map(\.translation).joined(separator: "\n")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isTranslating = false
        // N9: translate anything that arrived while this run was
        // going, so a static camera still catches up.
        if !pendingText.isEmpty, pendingText != lastTranslatedText {
            let next = pendingText
            pendingText = ""
            await translateIfNeeded(next)
        }
    }
}

/// Camera capture + throttled on-device OCR. Runs the session on its own
/// queue; publishes the latest recognized text (at most one OCR pass
/// every 2 seconds so the phone does not burn CPU on every frame).
@MainActor
final class LiveCameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var recognizedText = ""
    /// Item 12: the most recent frame handed to OCR (at most 2 seconds
    /// old) — the shutter freezes this frame.
    private(set) var latestFrame: (cgImage: CGImage, orientation: CGImagePropertyOrientation)?

    private let sessionQueue = DispatchQueue(label: "zhiyin.live-camera")
    private var ocrInFlight = false
    /// Item 12: the back camera, kept for the torch toggle.
    private var captureDevice: AVCaptureDevice?

    override init() {
        super.init()
        session.sessionPreset = .high
    }

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { return }
        sessionQueue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        // Item 12: leaving the page must not leave the torch on.
        if let device = captureDevice, device.hasTorch, device.torchMode == .on {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.torchMode = .off
            } catch {}
        }
    }

    /// Item 12: toggle the torch (flashlight). Returns the new state;
    /// false when the device has no torch or the toggle failed.
    func toggleTorch() -> Bool {
        guard let device = captureDevice, device.hasTorch else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = device.torchMode == .on ? .off : .on
            return device.torchMode == .on
        } catch {
            return false
        }
    }

    /// Item 12: show a still frame's OCR text in the view.
    func setRecognizedText(_ text: String) {
        recognizedText = text
    }

    private func configureAndStart() {
        guard !session.isRunning else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        captureDevice = device
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        session.startRunning()
    }

    private func ocr(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) {
        latestFrame = (cgImage, orientation)
        guard !ocrInFlight else { return }
        ocrInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.ocrInFlight = false } }
            let lines = try? await VisionTextRecognizer.recognizeText(in: cgImage, orientation: orientation)
            let text = lines.map { VisionTextRecognizer.plainText(from: $0) } ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                if !trimmed.isEmpty, trimmed != self.recognizedText {
                    self.recognizedText = trimmed
                }
            }
        }
    }
}

/// Shared render context for the live camera path. Only the serial
/// capture queue touches it, and the sample buffer is converted here
/// (nonisolated) so only the Sendable CGImage ever crosses to the
/// main actor — a CMSampleBuffer must not be captured by a Task or a
/// main-actor closure (Swift 6 rejects it either way).
private let liveCameraCIContext = CIContext()

/// Cheap pre-gate for the live camera OCR, checked on the capture
/// queue so idle frames never pay for a render. Guarded by its lock;
/// `nonisolated(unsafe)` because the compiler cannot verify lock
/// discipline. The main-actor `ocrInFlight` guard stays authoritative
/// for overlapping runs.
private let liveCameraThrottleLock = NSLock()
nonisolated(unsafe) private var liveCameraLastOCR = Date.distantPast

private func liveCameraOCRSlotDue() -> Bool {
    liveCameraThrottleLock.lock()
    defer { liveCameraThrottleLock.unlock() }
    let now = Date()
    guard now.timeIntervalSince(liveCameraLastOCR) >= 2 else { return false }
    liveCameraLastOCR = now
    return true
}

extension LiveCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard liveCameraOCRSlotDue() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = liveCameraCIContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        // N10: the back camera's sensor is landscape — in portrait
        // the pixels are sideways. Pass the orientation so Vision
        // reads the text upright.
        let orientation = Self.cgOrientation(from: UIDevice.current.orientation)
        Task { @MainActor in
            self.ocr(cgImage, orientation: orientation)
        }
    }

    /// N10: device orientation → the orientation of the back-camera
    /// pixel buffer relative to upright (portrait frames need a 90°
    /// clockwise correction, i.e. `.right`). Nonisolated: called
    /// from the nonisolated capture-output delegate.
    private nonisolated static func cgOrientation(from deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch deviceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }
}

/// UIView wrapper for the camera preview layer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
