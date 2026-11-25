import AVFoundation
import RunseCore
import SwiftData
import SwiftUI

/// Live camera translation (清单 10): point the camera at English text
/// and the Chinese translation appears on screen — no need to take a
/// photo first. Frames are OCR'd at most once every 2 seconds (Vision
/// on device), and the text is re-translated only when it changes.
struct LiveCameraView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]

    @StateObject private var camera = LiveCameraController()
    @State private var translation = ""
    @State private var lastTranslatedText = ""
    @State private var isTranslating = false
    @State private var errorMessage: String?

    private let pipeline = TranslationPipeline()

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
            VStack {
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
                        Text("把镜头对准要翻译的英文")
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
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("实时取景")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: camera.recognizedText) { _, text in
            Task { await translateIfNeeded(text) }
        }
        .task {
            await camera.start()
        }
        .onDisappear {
            camera.stop()
        }
    }

    @MainActor
    private func translateIfNeeded(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastTranslatedText, !isTranslating else { return }
        lastTranslatedText = trimmed
        isTranslating = true
        errorMessage = nil
        defer { isTranslating = false }
        do {
            guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
                throw LLMProviderError.invalidURL
            }
            let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
            let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
            guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
            let template = templates.first { $0.action == .translate }
                ?? PromptTemplate.builtIns().first { $0.action == .translate }!
            let target = TextLanguage.detect(trimmed).translationTarget
            let parts = TextSegmenter.segments(for: trimmed, maxChars: TextSegmenter.maxChars(for: profile))
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            let results = try await pipeline.translate(
                segments: parts,
                profile: profile,
                apiKey: apiKey,
                targetLanguage: target,
                template: template,
                glossary: [],
                tone: SettingsStore().translationTone,
                fallbackProfile: fallback?.profile,
                fallbackAPIKey: fallback?.apiKey
            ) { _, _ in }
            translation = results.map(\.translation).joined(separator: "\n")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private let sessionQueue = DispatchQueue(label: "zhiyin.live-camera")
    private let ciContext = CIContext()
    private var lastOCRDate = Date.distantPast
    private var ocrInFlight = false

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
    }

    private func configureAndStart() {
        guard !session.isRunning else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        session.startRunning()
    }

    private func ocr(_ sampleBuffer: CMSampleBuffer) {
        guard !ocrInFlight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOCRDate) >= 2 else { return }
        lastOCRDate = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        ocrInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.ocrInFlight = false } }
            let lines = try? await VisionTextRecognizer.recognizeText(in: cgImage)
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

extension LiveCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        Task { @MainActor in
            self.ocr(sampleBuffer)
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
