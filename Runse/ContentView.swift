import RunseCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var selection: Tab = .tryIt
    @State private var showingGetStarted = false
    private let settings = SettingsStore()

    var body: some View {
        TabView(selection: $selection) {
            TranslateView()
                .tabItem { Label("翻译", systemImage: "text.badge.checkmark") }
                .tag(Tab.translate)
            VoiceView()
                .tabItem { Label("语音", systemImage: "mic") }
                .tag(Tab.voice)
            InterpretationView()
                .tabItem { Label("同传", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.interpret)
            PhotoView()
                .tabItem { Label("拍照", systemImage: "camera") }
                .tag(Tab.photo)
            TryView()
                .tabItem { Label("Try", systemImage: "wand.and.stars") }
                .tag(Tab.tryIt)
            ProvidersView()
                .tabItem { Label("Providers", systemImage: "server.rack") }
                .tag(Tab.providers)
            PromptsView()
                .tabItem { Label("Prompts", systemImage: "text.quote") }
                .tag(Tab.prompts)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(Tab.history)
        }
        .fullScreenCover(isPresented: $showingGetStarted) {
            GetStartedGuideView {
                settings.hasSeenGetStartedGuide = true
                showingGetStarted = false
            }
        }
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("ZHIYIN_SCREENSHOTS") {
                showingGetStarted = true
            } else if !arguments.contains("ZHIYIN_SKIP_GUIDE") && !settings.hasSeenGetStartedGuide {
                showingGetStarted = true
            }
        }
    }

    enum Tab {
        case translate, voice, interpret, photo, tryIt, providers, prompts, settings, history
    }
}

struct GetStartedGuideView: View {
    let onDone: () -> Void
    @State private var currentStep = 0

    private let steps = GuideStep.steps
    private var step: GuideStep { steps[currentStep] }
    private var isLastStep: Bool { currentStep == steps.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(steps.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == currentStep ? Color.green : Color.secondary.opacity(0.25))
                            .frame(width: index == currentStep ? 26 : 8, height: 8)
                    }
                }
                .padding(.top, 18)
                .accessibilityLabel("Step \(currentStep + 1) of \(steps.count)")

                GuideStepPageView(step: step, stepNumber: currentStep + 1, stepCount: steps.count)
                    .id(currentStep)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: currentStep)

                Spacer(minLength: 0)
            }
            .navigationTitle("智音")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation {
                            currentStep = max(0, currentStep - 1)
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentStep == 0)
                    .accessibilityIdentifier("guide.back")

                    Button {
                        if isLastStep {
                            onDone()
                        } else {
                            withAnimation {
                                currentStep += 1
                            }
                        }
                    } label: {
                        Label(LocalizedStringKey(isLastStep ? "Start" : "Next"), systemImage: isLastStep ? "checkmark" : "chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("guide.next")
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

struct GuideStep {
    let title: String
    let detail: String
    let systemImage: String
    let example: String
    let demoState: GuideDemoState

    static let steps = [
        GuideStep(
            title: "Select text",
            detail: "In Safari, Notes, Mail, or another text app, touch and hold a word, then adjust the selection handles to include the text you want to change.",
            systemImage: "selection.pin.in.out",
            example: "Highlight a sentence, paragraph, or message before opening the menu.",
            demoState: .selection
        ),
        GuideStep(
            title: "Open the action menu",
            detail: "在选择菜单里点「分享」或「更多」。如果没看到智音，打开「更多」启用它，下次就能直接用。",
            systemImage: "square.and.arrow.up",
            example: "Look for the system share sheet or action list after selecting text.",
            demoState: .actionMenu
        ),
        GuideStep(
            title: "Pin Runse",
            detail: "如果智音在「更多」里被隐藏了，启用它并拖到靠前的位置，下次就能直接看到。",
            systemImage: "pin",
            example: "You only need to pin Runse once for each app or menu style where you use it.",
            demoState: .pinRunse
        ),
        GuideStep(
            title: "Choose Runse",
            detail: "在分享表单或操作列表里点智音。选中的文字会在智音里打开，可用操作都列在里面。",
            systemImage: "sparkles",
            example: "Runse receives only the selected text and prepares it for transformation.",
            demoState: .chooseRunse
        ),
        GuideStep(
            title: "Refine or translate",
            detail: "Choose Refine to improve wording, or Translate to convert the text into your default language. Copy the result back where you need it.",
            systemImage: "text.badge.checkmark",
            example: "Use Refine for clearer writing. Use Translate when the selected text should change languages.",
            demoState: .actions
        ),
        GuideStep(
            title: "Adjust defaults",
            detail: "Open Settings to change the default translation language. Open Providers if you need to update the model, endpoint, or API key.",
            systemImage: "gearshape",
            example: "You can reopen this guide later from Settings.",
            demoState: .settings
        )
    ]
}

enum GuideDemoState {
    case selection
    case actionMenu
    case pinRunse
    case chooseRunse
    case actions
    case settings
}

struct GuideStepPageView: View {
    let step: GuideStep
    let stepNumber: Int
    let stepCount: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.14))
                    Image(systemName: step.systemImage)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                Text(String.localizedStringWithFormat(NSLocalizedString("Step %lld of %lld", comment: "Guide step progress"), stepNumber, stepCount))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text(LocalizedStringKey(step.title))
                    .font(.largeTitle.bold())
                Text(LocalizedStringKey(step.detail))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            GuideDemoTextView(state: step.demoState)

            Text(LocalizedStringKey(step.example))
                .font(.callout)
                .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GuideDemoTextView: View {
    let state: GuideDemoState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            demoText

            switch state {
            case .selection:
                selectionHint
            case .actionMenu:
                actionMenu
            case .pinRunse:
                pinRunse
            case .chooseRunse:
                actionMenu
                runseChoice
            case .actions:
                runseActions
            case .settings:
                settingsHint
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.20))
        }
    }

    private var demoText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Demo Text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("The product update is good but it sounds a little rough. Please make it clearer for customers.")
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if state != .settings {
                        Text("Selected")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green, in: Capsule())
                            .offset(x: 10, y: -10)
                    }
                }
        }
    }

    private var selectionHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .foregroundStyle(.green)
            Text("Touch and hold this sample text, then drag the handles to select the part you want Runse to process.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionMenu: some View {
        HStack(spacing: 8) {
            demoPill("Copy", systemImage: "doc.on.doc")
            demoPill("Share", systemImage: "square.and.arrow.up", highlighted: true)
            demoPill("More", systemImage: "ellipsis")
        }
    }

    private var runseChoice: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.green)
            Text("智音")
                .font(.headline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var pinRunse: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                demoPill("More", systemImage: "ellipsis", highlighted: true)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                demoPill("Enable Runse", systemImage: "switch.2")
            }

            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                Text("Drag Runse near the top")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Image(systemName: "pin.fill")
                    .foregroundStyle(.green)
            }
            .padding(12)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var runseActions: some View {
        HStack(spacing: 10) {
            demoPill("Refine", systemImage: "wand.and.sparkles", highlighted: true)
            demoPill("Translate", systemImage: "globe", highlighted: true)
        }
    }

    private var settingsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .foregroundStyle(.green)
            Text("Settings keeps the guide available and stores your default translation language.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func demoPill(_ title: String, systemImage: String, highlighted: Bool = false) -> some View {
        Label(LocalizedStringKey(title), systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(highlighted ? .white : .primary)
            .background(highlighted ? Color.green : Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct ProvidersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var historyItems: [TransformHistory]
    @State private var showingEditor = false
    @State private var editingProfile: ProviderProfile?
    private var visibleProfiles: [ProviderProfile] {
        profiles.filter { $0.id != RunseConstants.defaultProfileID }
    }

    var body: some View {
        NavigationStack {
            List {
                if visibleProfiles.isEmpty {
                    ContentUnavailableView("No Custom Providers", systemImage: "server.rack", description: Text("Add a provider when you want to use a custom model or endpoint."))
                }

                ForEach(visibleProfiles) { profile in
                    Button {
                        editingProfile = profile
                    } label: {
                        ProviderRowView(profile: profile, usage: usage(for: profile))
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        modelContext.delete(visibleProfiles[offset])
                    }
                    try? modelContext.save()
                }
            }
            .navigationTitle("Providers")
            .toolbar {
                Button {
                    editingProfile = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingEditor) {
                ProviderEditorView(profile: nil)
            }
            .sheet(item: $editingProfile) { profile in
                ProviderEditorView(profile: profile)
            }
        }
    }

    private func usage(for profile: ProviderProfile) -> ProviderUsage {
        historyItems.reduce(into: ProviderUsage()) { partial, item in
            let matchesProviderID = item.providerID == profile.id
            let matchesLegacyHistory = item.providerID == nil && item.providerName == profile.name && item.model == profile.model
            guard matchesProviderID || matchesLegacyHistory else { return }
            partial.requestCount += 1
            partial.promptTokens += item.promptTokens
            partial.completionTokens += item.completionTokens
            partial.totalTokens += item.totalTokens
        }
    }
}

struct ProviderUsage {
    var requestCount = 0
    var promptTokens = 0
    var completionTokens = 0
    var totalTokens = 0
}

struct ProviderRowView: View {
    let profile: ProviderProfile
    let usage: ProviderUsage
    @State private var hasAPIKey: Bool?

    private var isConfigured: Bool {
        !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profile.chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: profile.baseURL) != nil
    }

    private var status: ProviderStatus {
        if !isConfigured { return .incomplete }
        guard let hasAPIKey else { return .checking }
        guard hasAPIKey else { return .missingKey }
        switch profile.apiTestStatus {
        case .passed: return .ready
        case .failed: return .failed
        case .testing: return .checking
        case .untested: return .untested
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    HStack(spacing: 0) {
                        Text(LocalizedStringKey(profile.kind.title))
                        Text(" · \(profile.model)")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                ProviderStatusBadge(status: status)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let apiTestMessage = profile.apiTestMessage, !apiTestMessage.isEmpty {
                    Text(apiTestMessage)
                        .font(.caption)
                        .foregroundStyle(status.color)
                        .lineLimit(2)
                }

                if usage.requestCount == 0 {
                    Text("No usage yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String.localizedStringWithFormat(NSLocalizedString("%lld requests · %lld tokens", comment: "Provider usage summary"), usage.requestCount, usage.totalTokens))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(String.localizedStringWithFormat(NSLocalizedString("Input %lld · Output %lld", comment: "Provider input and output token usage"), usage.promptTokens, usage.completionTokens))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: profile.id) {
            await refreshKeyStatus()
        }
    }

    private func refreshKeyStatus() async {
        guard isConfigured else {
            hasAPIKey = false
            return
        }
        let key = try? await KeychainStore(accessGroup: KeychainAccessGroup.current())
            .load(service: KeychainStore.providerAPIKeyService, account: profile.id)
        hasAPIKey = !(key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

enum ProviderStatus {
    case ready
    case failed
    case untested
    case missingKey
    case incomplete
    case checking

    var title: LocalizedStringKey {
        switch self {
        case .ready: "Ready"
        case .failed: "Failed"
        case .untested: "Untested"
        case .missingKey: "Missing Key"
        case .incomplete: "Incomplete"
        case .checking: "Checking"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .untested: "questionmark.circle.fill"
        case .missingKey: "key.slash.fill"
        case .incomplete: "exclamationmark.triangle.fill"
        case .checking: "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .failed: .red
        case .missingKey, .incomplete, .untested: .orange
        case .checking: .secondary
        }
    }
}

struct ProviderStatusBadge: View {
    let status: ProviderStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}

struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let profile: ProviderProfile?
    @State private var preset: ProviderPreset
    @State private var name: String
    @State private var kind: ProviderKind
    @State private var baseURL: String
    @State private var endpoint: String
    @State private var model: String
    @State private var extraHeaders: String
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var saveMessage: String?

    init(profile: ProviderProfile?) {
        self.profile = profile
        let inferredPreset = ProviderPreset.infer(from: profile)
        _preset = State(initialValue: inferredPreset)
        _name = State(initialValue: profile?.name ?? "")
        _kind = State(initialValue: profile?.kind ?? .openAICompatible)
        _baseURL = State(initialValue: profile?.baseURL ?? "")
        _endpoint = State(initialValue: profile?.chatEndpoint ?? "/v1/chat/completions")
        _model = State(initialValue: profile?.model ?? "")
        _extraHeaders = State(initialValue: profile?.extraHeadersJSON ?? "{}")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $preset) {
                    ForEach(ProviderPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.title)).tag(preset)
                    }
                }
                .onChange(of: preset) { _, value in
                    applyPreset(value, overwriteName: profile == nil || name.isEmpty || ProviderPreset.allPresetNames.contains(name))
                }

                TextField("Name", text: $name)

                if preset == .custom {
                    Picker("API Type", selection: $kind) {
                        ForEach(ProviderKind.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Endpoint", text: $endpoint)
                        .textInputAutocapitalization(.never)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                    TextField("Extra headers JSON", text: $extraHeaders, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    LabeledContent("API Type", value: kind.title)
                    LabeledContent("Model", value: model)
                }

                SecureField("API key", text: $apiKey)

                if isSaving {
                    HStack {
                        ProgressView()
                        Text("Testing API")
                    }
                } else if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(profile == nil ? String(localized: "New Provider") : String(localized: "Edit Provider"))
            .onAppear {
                applyPreset(preset, overwriteName: profile == nil && name.isEmpty)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveAndTest() }
                    }
                    .disabled(isSaving || name.isEmpty || baseURL.isEmpty || model.isEmpty)
                }
            }
        }
    }

    @MainActor
    private func saveAndTest() async {
        applyPreset(preset, overwriteName: false)
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }

        let target = profile ?? ProviderProfile(name: name, kind: kind, baseURL: baseURL, chatEndpoint: endpoint, model: model)
        target.name = name
        target.kind = kind
        target.baseURL = baseURL
        target.chatEndpoint = endpoint
        target.model = model
        target.extraHeadersJSON = extraHeaders
        target.updatedAt = .now
        if profile == nil { modelContext.insert(target) }
        let keychain = KeychainStore(accessGroup: KeychainAccessGroup.current())
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            do {
                try await keychain.save(apiKey, service: KeychainStore.providerAPIKeyService, account: target.id)
            } catch {
                target.apiTestStatus = .failed
                target.apiTestMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                target.apiTestedAt = .now
                try? modelContext.save()
                saveMessage = target.apiTestMessage
                return
            }
        }

        let savedAPIKey = trimmedAPIKey.isEmpty ? (try? await keychain.load(service: KeychainStore.providerAPIKeyService, account: target.id)) : trimmedAPIKey
        guard let savedAPIKey, !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            target.apiTestStatus = .untested
            target.apiTestMessage = String(localized: "Saved without API test")
            target.apiTestedAt = nil
            try? modelContext.save()
            dismiss()
            return
        }

        target.apiTestStatus = .testing
        target.apiTestMessage = String(localized: "Testing API")
        target.apiTestedAt = .now
        try? modelContext.save()

        do {
            let result = try await ProviderAPITester.test(profile: target, apiKey: savedAPIKey)
            target.apiTestStatus = .passed
            target.apiTestMessage = String.localizedStringWithFormat(
                NSLocalizedString("API test passed · %lld tokens", comment: "Provider API test success with token count"),
                result.totalTokens
            )
            target.apiTestedAt = .now
        } catch {
            target.apiTestStatus = .failed
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            target.apiTestMessage = String.localizedStringWithFormat(NSLocalizedString("API test failed: %@", comment: "Provider API test failure"), message)
            target.apiTestedAt = .now
            saveMessage = target.apiTestMessage
        }

        try? modelContext.save()
        if target.apiTestStatus == .passed {
            dismiss()
        }
    }

    private func applyPreset(_ preset: ProviderPreset, overwriteName: Bool) {
        guard let configuration = preset.configuration else { return }
        if overwriteName {
            name = configuration.name
        }
        kind = configuration.kind
        baseURL = configuration.baseURL
        endpoint = configuration.endpoint
        model = configuration.model
        extraHeaders = configuration.extraHeaders
    }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case deepSeek
    case deepSeekPro
    case kimi
    case miniMax
    case glm

    struct Configuration {
        let name: String
        let kind: ProviderKind
        let baseURL: String
        let endpoint: String
        let model: String
        let extraHeaders: String
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .deepSeek: "DeepSeek China"
        case .deepSeekPro: "DeepSeek Pro"
        case .kimi: "Kimi China"
        case .miniMax: "MiniMax China"
        case .glm: "GLM China"
        }
    }

    var configuration: Configuration? {
        switch self {
        case .custom:
            nil
        case .deepSeek:
            Configuration(
                name: "DeepSeek China",
                kind: .openAICompatible,
                baseURL: "https://api.deepseek.com",
                endpoint: "/chat/completions",
                model: "deepseek-flash",
                extraHeaders: "{}"
            )
        case .deepSeekPro:
            Configuration(
                name: "DeepSeek Pro",
                kind: .openAICompatible,
                baseURL: "https://api.deepseek.com",
                endpoint: "/chat/completions",
                model: "deepseek-v4-pro",
                extraHeaders: "{}"
            )
        case .kimi:
            Configuration(
                name: "Kimi China",
                kind: .openAICompatible,
                baseURL: "https://api.moonshot.cn/v1",
                endpoint: "/chat/completions",
                model: "kimi-k2.5",
                extraHeaders: "{}"
            )
        case .miniMax:
            Configuration(
                name: "MiniMax China",
                kind: .openAICompatible,
                baseURL: "https://api.minimaxi.com/v1",
                endpoint: "/chat/completions",
                model: "MiniMax-M2.5",
                extraHeaders: "{}"
            )
        case .glm:
            Configuration(
                name: "GLM China",
                kind: .openAICompatible,
                baseURL: "https://open.bigmodel.cn/api/paas/v4",
                endpoint: "/chat/completions",
                model: "glm-5",
                extraHeaders: "{}"
            )
        }
    }

    static var allPresetNames: Set<String> {
        Set(allCases.compactMap(\.configuration?.name))
    }

    static func infer(from profile: ProviderProfile?) -> ProviderPreset {
        guard let profile else { return .custom }
        let normalizedBaseURL = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return allCases.first {
            guard let configuration = $0.configuration else { return false }
            return configuration.baseURL == normalizedBaseURL && configuration.model == profile.model
        } ?? .custom
    }
}

struct PromptsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PromptTemplate.name) private var templates: [PromptTemplate]

    var body: some View {
        NavigationStack {
            List {
                ForEach(templates) { template in
                    NavigationLink(template.name) {
                        PromptEditorView(template: template)
                    }
                }
            }
            .navigationTitle("Prompts")
            .toolbar {
                Button("Restore") {
                    for template in templates {
                        modelContext.delete(template)
                    }
                    for template in PromptTemplate.builtIns() {
                        modelContext.insert(template)
                    }
                    try? modelContext.save()
                }
            }
        }
    }
}

struct PromptEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var template: PromptTemplate

    var body: some View {
        Form {
            TextField("Name", text: $template.name)
            TextField("System template", text: $template.systemTemplate, axis: .vertical)
                .lineLimit(4...8)
            TextField("User template", text: $template.userTemplate, axis: .vertical)
                .lineLimit(8...16)
            Text("Variables: {{selected_text}}, {{action}}, {{target_language}}, {{tone}}, {{length}}, {{formality}}, {{output_locale}}, {{custom_instruction}}")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(String(localized: String.LocalizationValue(template.action.title)))
        .onDisappear {
            template.updatedAt = .now
            try? modelContext.save()
        }
    }
}

struct SettingsView: View {
    @State private var language = SettingsStore().defaultTranslationLanguage
    @State private var showingGetStarted = false
    @State private var showingModelPicker = false
    @State private var voiceConfigured = false
    private let settings = SettingsStore()

    private var currentModelName: String {
        ModelCatalog.option(id: settings.selectedModelOptionID, voiceConfigured: voiceConfigured)?.name
            ?? "DeepSeek 日常"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型") {
                    HStack {
                        Text("当前模型")
                        Spacer()
                        Text(currentModelName)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showingModelPicker = true
                    } label: {
                        Label("选择模型", systemImage: "cpu")
                    }
                }

                Section("语音") {
                    HStack {
                        Text("豆包语音")
                        Spacer()
                        Text(voiceConfigured ? "已配置" : "未配置")
                            .foregroundStyle(voiceConfigured ? .green : .orange)
                    }
                    if !voiceConfigured {
                        Text("去“语音”页填 AppID 和 Access Token（只存钥匙串）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Preferences") {
                    TextField("Default translation language", text: $language)
                        .onChange(of: language) { _, value in
                            settings.defaultTranslationLanguage = value
                        }
                }

                Section("Help") {
                    Button {
                        showingGetStarted = true
                    } label: {
                        Label("Get Started Guide", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingGetStarted) {
                GetStartedGuideView {
                    showingGetStarted = false
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet()
            }
            .task {
                let config = await VolcanoVoiceStore.load()
                voiceConfigured = config != nil
            }
        }
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var items: [TransformHistory]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.resultExcerpt)
                            .font(.body)
                        HStack(spacing: 0) {
                            Text(LocalizedStringKey(item.actionRawValue.capitalized))
                            Text(" · \(item.providerName) · \(item.model)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        modelContext.delete(items[offset])
                    }
                    try? modelContext.save()
                }
            }
            .navigationTitle("History")
            .toolbar {
                Button("Clear") {
                    for item in items { modelContext.delete(item) }
                    try? modelContext.save()
                }
            }
        }
    }
}
