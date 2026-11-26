import PhotosUI
import ImageIO
import RunseCore
import SwiftData
import SwiftUI
import UIKit

/// Photo and image translation: take a photo or pick an image, the
/// on-device Vision framework reads the text, and the text goes through
/// the same translation pipeline as typed input.
struct PhotoView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @Query(sort: \GlossaryEntry.sourceTerm) private var glossaryEntries: [GlossaryEntry]

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var pickedImage: UIImage?
    @State private var recognizedText = ""
    @State private var translation = ""
    @State private var isWorking = false
    // S24: stored handle for the translation run (isWorking is
    // shared with OCR, so the 取消 button keys off this handle).
    @State private var translationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var didCopy = false

    private let settings = SettingsStore()
    private let pipeline = TranslationPipeline()

    var body: some View {
        NavigationStack {
            Form {
                Section("图片") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("从相册选图", systemImage: "photo")
                    }
                    .onChange(of: selectedPhoto) { _, item in
                        Task { await loadPhoto(item) }
                    }
                    Button {
                        // N12: presenting a .camera picker on a
                        // device without a camera crashes. Check
                        // first and say so instead of opening it.
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            errorMessage = "这台设备没有相机。"
                            return
                        }
                        showingCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    NavigationLink("实时取景翻译") {
                        LiveCameraView()
                    }
                    if let pickedImage {
                        Image(uiImage: pickedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !recognizedText.isEmpty {
                    Section("识别出的文字") {
                        TextEditor(text: $recognizedText)
                            .frame(minHeight: 100)
                        Text("认错的字可以直接改。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        translationTask = Task { await runTranslation() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("翻译", systemImage: "globe")
                        }
                    }
                    .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                    if translationTask != nil {
                        Button {
                            translationTask?.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                        }
                    }

                    Spacer()

                    Button {
                        UIPasteboard.general.string = translation
                        didCopy = true
                    } label: {
                        Label(LocalizedStringKey(didCopy ? "Copied" : "Copy"), systemImage: "doc.on.doc")
                    }
                    .disabled(translation.isEmpty || isWorking)
                }
                .buttonStyle(.borderless)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if !translation.isEmpty {
                    Section("译文") {
                        Text(translation)
                    }
                }
            }
            .navigationTitle("拍照翻译")
            .sheet(isPresented: $showingCamera) {
                CameraPickerView(image: $pickedImage)
            }
            .onChange(of: pickedImage) { _, image in
                guard let image else { return }
                Task { await recognize(image) }
            }
            .onChange(of: recognizedText) { _, _ in didCopy = false }
        }
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "读不到这张图。"
                return
            }
            pickedImage = image
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// N10: UIImage.Orientation → CGImagePropertyOrientation, so
    /// Vision reads a portrait photo upright instead of sideways.
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
    private func recognize(_ image: UIImage) async {
        isWorking = true
        errorMessage = nil
        translation = ""
        defer { isWorking = false }
        guard let cgImage = image.cgImage else {
            errorMessage = "读不到这张图。"
            return
        }
        do {
            // N10: pass the photo's orientation — the CGImage pixels
            // of a portrait photo are landscape.
            let lines = try await VisionTextRecognizer.recognizeText(in: cgImage, orientation: Self.cgOrientation(from: image.imageOrientation))
            recognizedText = VisionTextRecognizer.plainText(from: lines)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func runTranslation() async {
        isWorking = true
        errorMessage = nil
        didCopy = false
        // S24: a long translation must not let the screen lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isWorking = false
            translationTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            let request = try await TranslationRequestResolver.resolve(profiles: profiles, templates: templates)
            let profile = request.profile
            let apiKey = request.apiKey
            let template = request.template
            let target = TextLanguage.detect(recognizedText).translationTarget
            let parts = TextSegmenter.segments(for: recognizedText, maxChars: TextSegmenter.maxChars(for: profile))
            var partials = Array(repeating: "", count: parts.count)
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve()
            // S1: partial outcome — a segment that fails mid-run keeps the
            // finished part on screen instead of throwing it all away.
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
            ) { index, partial in
                partials[index] = partial
                translation = partials.joined(separator: "\n")
            }
            let results = outcome.results
            translation = results.map(\.translation).joined(separator: "\n")
            if let failedIndex = outcome.failedSegmentIndex, let error = outcome.error {
                errorMessage = "第 \(failedIndex + 1) 段翻译失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)（已译部分已保留）"
            }
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
                    sourceExcerpt: TextExcerpt.make(recognizedText),
                    resultExcerpt: TextExcerpt.make(translation),
                    providerName: isFallback ? (fallback?.profile.name ?? profile.name) : profile.name,
                    model: model,
                    action: .translate,
                    targetLanguage: target,
                    status: outcome.isComplete
                        ? (pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success")
                        : "partial · 第 \(outcome.failedSegmentIndex! + 1) 段失败",
                    promptTokens: usage["prompt_tokens"] ?? 0,
                    completionTokens: usage["completion_tokens"] ?? 0,
                    totalTokens: usage["total_tokens"] ?? 0
                ))
            }
            try? modelContext.save()
        } catch is CancellationError {
            // S24: cancelled via 取消 — finished segments stay on
            // screen, no error message.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Camera picker (UIImagePickerController). Photo library uses
/// PhotosPicker instead, which needs no library permission.
struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(image: $image, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var image: Binding<UIImage?>
        var dismiss: DismissAction

        init(image: Binding<UIImage?>, dismiss: DismissAction) {
            self.image = image
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            image.wrappedValue = info[.originalImage] as? UIImage
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
