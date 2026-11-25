import PhotosUI
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

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var pickedImage: UIImage?
    @State private var recognizedText = ""
    @State private var translation = ""
    @State private var isWorking = false
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
                        showingCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera")
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
                        Task { await runTranslation() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Label("翻译", systemImage: "globe")
                        }
                    }
                    .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

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
            let lines = try await VisionTextRecognizer.recognizeText(in: cgImage)
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
        defer { isWorking = false }
        do {
            guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
                throw LLMProviderError.invalidURL
            }
            let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
            let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
            guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
            let template = templates.first { $0.action == .translate }
                ?? PromptTemplate.builtIns().first { $0.action == .translate }!
            let target = TextLanguage.detect(recognizedText).translationTarget
            let parts = TextSegmenter.segments(for: recognizedText, maxChars: TextSegmenter.maxChars(for: profile))
            var partials = Array(repeating: "", count: parts.count)
            let fallback = profile.isQwenMT ? nil : await QwenMTBackup.resolve(profiles: profiles)
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
            ) { index, partial in
                partials[index] = partial
                translation = partials.joined(separator: "\n")
            }
            translation = results.map(\.translation).joined(separator: "\n")
            let usage = pipeline.lastUsage
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(recognizedText),
                resultExcerpt: TextExcerpt.make(translation),
                providerName: profile.name,
                model: profile.model,
                action: .translate,
                targetLanguage: target,
                status: pipeline.lastFallbackUsed ? "success · 部分段落由 Qwen-MT 备用完成" : "success",
                promptTokens: usage["prompt_tokens"] ?? 0,
                completionTokens: usage["completion_tokens"] ?? 0,
                totalTokens: usage["total_tokens"] ?? 0
            ))
            try? modelContext.save()
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
