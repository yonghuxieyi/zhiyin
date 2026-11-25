import RunseCore
import SwiftData
import SwiftUI
import UIKit

struct TryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
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

    private let settings = SettingsStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    TextEditor(text: $inputText)
                        .frame(minHeight: 100)
                        .focused($inputFocused)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Button("Select All") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                }
                                .disabled(!inputFocused || inputText.isEmpty)
                                Spacer()
                                Button("Done") { inputFocused = false }
                            }
                        }
                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            inputText = clipboard
                        }
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasStrings)
                }

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
                    Section("Target language") {
                        TextField("Target language", text: $targetLanguage)
                            .textInputAutocapitalization(.words)
                    }
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
                    .disabled(inputText.isEmpty || isLoading)

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

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Section("Result") {
                    TextEditor(text: $result)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle("Try")
        }
        .onChange(of: inputText) { _, _ in didCopy = false }
        .onChange(of: result) { _, _ in didCopy = false }
    }

    @MainActor
    private func runTransform() async {
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
            let template = templates.first { $0.action == action }
                ?? PromptTemplate.builtIns().first { $0.action == action }!
            let context = PromptContext(
                selectedText: inputText,
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
            modelContext.insert(TransformHistory(
                providerID: profile.id,
                sourceExcerpt: TextExcerpt.make(inputText),
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
}
