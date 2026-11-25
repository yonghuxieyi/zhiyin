import RunseCore
import SwiftData
import SwiftUI
import UIKit

struct ExtensionRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    let selectedText: String
    let done: () -> Void

    @State private var action: TransformAction = .refine
    @State private var tone: Tone = .natural
    @State private var formality: Formality = .neutral
    @State private var length: OutputLength = .same
    @State private var targetLanguage = SettingsStore().defaultTranslationLanguage
    @State private var customInstruction = ""
    @State private var result = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var didCopy = false
    @State private var completedRequestFingerprint: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Action", selection: $action) {
                    ForEach(TransformAction.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)

                switch action {
                case .refine:
                    Picker("Tone", selection: $tone) {
                        ForEach(Tone.allCases) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                    }
                    Picker("Formality", selection: $formality) {
                        ForEach(Formality.allCases) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                    }
                    Picker("Length", selection: $length) {
                        ForEach(OutputLength.allCases) { Text(LocalizedStringKey($0.rawValue.capitalized)).tag($0) }
                    }
                case .translate:
                    targetLanguageControls
                case .pinyin:
                    EmptyView()
                }

                TextField("Custom instruction", text: $customInstruction, axis: .vertical)
                    .lineLimit(2...4)

                HStack {
                    Button {
                        Task { await runTransform() }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Label("Run", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(selectedText.isEmpty || isLoading)

                    Spacer()

                    Button {
                        UIPasteboard.general.string = result
                        didCopy = true
                    } label: {
                        Label(LocalizedStringKey(didCopy ? "Copied" : "Copy"), systemImage: "doc.on.doc")
                    }
                    .disabled(result.isEmpty || isLoading)
                }
                .buttonStyle(.borderless)

                Section("Selected Text") {
                    Text(selectedText.isEmpty ? "No text received." : selectedText)
                        .lineLimit(5)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Section("Result") {
                    TextEditor(text: $result)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("智音")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { done() }
                }
            }
        }
    }

    private var targetLanguageControls: some View {
        Section("Target language") {
            Menu {
                ForEach(CommonTargetLanguage.all) { language in
                    Button {
                        targetLanguage = language.value
                    } label: {
                        if targetLanguage == language.value {
                            Label(LocalizedStringKey(language.title), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(language.title))
                        }
                    }
                }
            } label: {
                HStack {
                    Text("Language")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(targetLanguage.isEmpty ? String(localized: "Select…") : targetLanguage)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }

            TextField("Custom target language", text: $targetLanguage)
                .textInputAutocapitalization(.words)
        }
    }

    @MainActor
    private func runTransform() async {
        let requestFingerprint = transformRequestFingerprint
        guard result.isEmpty || completedRequestFingerprint != requestFingerprint else {
            return
        }

        isLoading = true
        errorMessage = nil
        didCopy = false
        defer { isLoading = false }

        do {
            guard let profile = profiles.first(where: \.isDefault) ?? profiles.first else {
                throw LLMProviderError.invalidURL
            }
            let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
            let apiKey = try await keychain.load(service: KeychainStore.providerAPIKeyService, account: profile.id)
            guard let apiKey, !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
            let template = templates.first { $0.action == action } ?? PromptTemplate.builtIns().first { $0.action == action }!
            let context = PromptContext(
                selectedText: selectedText,
                action: action,
                targetLanguage: targetLanguage,
                tone: tone,
                length: length,
                formality: formality,
                customInstruction: customInstruction
            )
            let prompt = PromptRenderer.render(template: template, context: context)
            let request = LLMRequest(action: action, model: profile.model, systemPrompt: prompt.system, userPrompt: prompt.user)
            let client = HTTPProviderClient(profile: profile, apiKey: apiKey)
            result = ""
            let response = try await client.complete(request) { partial in
                result = partial
            }
            result = response.text
            completedRequestFingerprint = requestFingerprint
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(selectedText),
                resultExcerpt: TextExcerpt.make(response.text),
                providerName: profile.name,
                model: response.model ?? profile.model,
                action: action,
                targetLanguage: action == .translate ? targetLanguage : nil,
                status: "success",
                promptTokens: response.promptTokens,
                completionTokens: response.completionTokens,
                totalTokens: response.totalTokens
            ))
            try? modelContext.save()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var transformRequestFingerprint: String {
        [
            selectedText,
            action.rawValue,
            targetLanguage,
            tone.rawValue,
            length.rawValue,
            formality.rawValue,
            customInstruction
        ].joined(separator: "\u{1F}")
    }
}

private struct CommonTargetLanguage: Identifiable {
    let title: String
    let value: String

    var id: String { value }

    static let all = [
        CommonTargetLanguage(title: "English", value: "English"),
        CommonTargetLanguage(title: "Simplified Chinese", value: "Simplified Chinese"),
        CommonTargetLanguage(title: "Traditional Chinese", value: "Traditional Chinese"),
        CommonTargetLanguage(title: "Japanese", value: "Japanese"),
        CommonTargetLanguage(title: "Korean", value: "Korean"),
        CommonTargetLanguage(title: "Spanish", value: "Spanish"),
        CommonTargetLanguage(title: "French", value: "French"),
        CommonTargetLanguage(title: "German", value: "German")
    ]
}
