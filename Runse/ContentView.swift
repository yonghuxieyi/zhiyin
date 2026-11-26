import RunseCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var selection: Tab = .translate
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
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
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
        case translate, voice, interpret, photo, settings
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
            title: "选中文字",
            detail: "在 Safari、备忘录、邮件或其他文字 App 里，长按一个词，再拖动选区手柄，选中想改的文字。",
            systemImage: "selection.pin.in.out",
            example: "打开菜单之前，先选中一句话、一段话或一条消息。",
            demoState: .selection
        ),
        GuideStep(
            title: "打开操作菜单",
            detail: "在选择菜单里点「分享」或「更多」。如果没看到智音，打开「更多」启用它，下次就能直接用。",
            systemImage: "square.and.arrow.up",
            example: "选中文字后，在系统分享表单或操作列表里找智音。",
            demoState: .actionMenu
        ),
        GuideStep(
            title: "固定智音",
            detail: "如果智音在「更多」里被隐藏了，启用它并拖到靠前的位置，下次就能直接看到。",
            systemImage: "pin",
            example: "每个 App 或每种菜单样式只需固定一次智音。",
            demoState: .pinRunse
        ),
        GuideStep(
            title: "选择智音",
            detail: "在分享表单或操作列表里点智音。选中的文字会在智音里打开，可用操作都列在里面。",
            systemImage: "sparkles",
            example: "智音只会收到你选中的文字，并为它准备好操作。",
            demoState: .chooseRunse
        ),
        GuideStep(
            title: "润色或翻译",
            detail: "选「润色」可以改得更通顺，选「翻译」可以译成你的默认语言，再把结果复制回去。",
            systemImage: "text.badge.checkmark",
            example: "想让表达更清楚就用润色，想换语言就用翻译。",
            demoState: .actions
        ),
        GuideStep(
            title: "调整默认设置",
            detail: "在设置里改默认翻译语言和语气，或换模型。",
            systemImage: "gearshape",
            example: "以后也可以在设置里重新打开这份引导。",
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
            Text("长按这段示例文字，再拖动手柄，选中想让智音处理的部分。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionMenu: some View {
        HStack(spacing: 8) {
            demoPill("拷贝", systemImage: "doc.on.doc")
            demoPill("分享", systemImage: "square.and.arrow.up", highlighted: true)
            demoPill("更多", systemImage: "ellipsis")
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
                demoPill("更多", systemImage: "ellipsis", highlighted: true)
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                demoPill("启用智音", systemImage: "switch.2")
            }

            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                Text("把智音拖到靠前的位置")
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
            demoPill("润色", systemImage: "wand.and.sparkles", highlighted: true)
            demoPill("翻译", systemImage: "globe", highlighted: true)
        }
    }

    private var settingsHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .foregroundStyle(.green)
            Text("设置里可以重新打开这份引导，也能改默认翻译语言。")
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


struct SettingsView: View {
    @State private var language = SettingsStore().defaultTranslationLanguage
    @State private var tone = SettingsStore().translationTone
    @State private var showingGetStarted = false
    @State private var showingModelPicker = false
    @State private var voiceConfigured = false
    @State private var qwenConfigured = false
    @State private var dashScopeKey = ""
    @State private var dashScopeSaved = false
    @State private var dashScopeError: String?
    @State private var dashScopeWorkspaceID = ""
    @State private var workspaceSaved = false
    @State private var providerKey = ""
    @State private var providerKeyConfigured = false
    @State private var providerKeySaved = false
    @State private var providerKeyError: String?
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var historyItems: [TransformHistory]
    private let settings = SettingsStore()

    private var currentModelName: String {
        ModelCatalog.option(id: settings.selectedModelOptionID, voiceConfigured: voiceConfigured, qwenConfigured: qwenConfigured)?.name
            ?? "DeepSeek 日常"
    }

    /// SwiftData profile id backing the currently selected model option.
    /// Qwen-MT options use the DashScope key (see the Qwen-MT section
    /// below); every other profile uses its own key under
    /// `Zhiyin.ProviderAPIKey` (M1).
    private var currentProfileID: String? {
        ModelCatalog.option(id: settings.selectedModelOptionID, voiceConfigured: voiceConfigured, qwenConfigured: qwenConfigured)?.profileID
    }

    private var isCurrentModelQwenMT: Bool {
        guard let id = currentProfileID else { return false }
        return id == QwenMT.flashProfileID || id == QwenMT.plusProfileID
    }

    private func refreshProviderKeyStatus() {
        Task {
            if let profileID = currentProfileID, !isCurrentModelQwenMT {
                providerKeyConfigured = await ProviderKeyStore.hasKey(profileID: profileID)
            } else {
                providerKeyConfigured = false
            }
        }
    }

    private var spend: SpendCalculator.Summary {
        SpendCalculator.summary(for: historyItems)
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
                    // M1: the app previously had no way to save a
                    // DeepSeek key at all — only loads — so the main
                    // model could never be called after install.
                    if isCurrentModelQwenMT {
                        Text("Qwen-MT 用下面的 DashScope Key，不用在这里填。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let profileID = currentProfileID {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text(providerKeyConfigured ? "已配置" : "未配置")
                                .foregroundStyle(providerKeyConfigured ? .green : .orange)
                        }
                        SecureField("粘贴当前模型的 API Key", text: $providerKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存 Key") {
                            Task {
                                guard let key = ProviderKeyStore.normalized(providerKey) else { return }
                                do {
                                    try await ProviderKeyStore.saveKey(key, profileID: profileID)
                                    providerKeyConfigured = true
                                    providerKeySaved = true
                                    providerKeyError = nil
                                    providerKey = ""
                                } catch {
                                    providerKeyError = "保存失败：\(error.localizedDescription)"
                                }
                            }
                        }
                        .disabled(ProviderKeyStore.normalized(providerKey) == nil)
                        if providerKeySaved {
                            Text("已保存到钥匙串。Key 只存手机钥匙串，不进代码。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let providerKeyError {
                            Text(providerKeyError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        if !providerKeyConfigured {
                            Text("没配 Key 时翻译会报“缺少 API Key”，先在这里粘贴保存。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

                Section("Qwen-MT 备用") {
                    HStack {
                        Text("DashScope Key")
                        Spacer()
                        Text(qwenConfigured ? "已配置" : "未配置")
                            .foregroundStyle(qwenConfigured ? .green : .orange)
                    }
                    SecureField("粘贴 DashScope API Key", text: $dashScopeKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存 Key") {
                        Task {
                            let key = dashScopeKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            do {
                                try await DashScopeStore.saveKey(key)
                                qwenConfigured = true
                                dashScopeSaved = true
                                dashScopeError = nil
                                dashScopeKey = ""
                            } catch {
                                dashScopeError = "保存失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(dashScopeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if dashScopeSaved {
                        Text("已保存到钥匙串。DeepSeek 出错时，Qwen-MT 会自动顶上。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let dashScopeError {
                        Text(dashScopeError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("业务空间 ID（可选）", text: $dashScopeWorkspaceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存业务空间 ID") {
                        Task {
                            do {
                                try await DashScopeStore.saveWorkspaceID(dashScopeWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines))
                                workspaceSaved = true
                            } catch {
                                dashScopeError = "保存失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    if workspaceSaved {
                        Text("业务空间 ID 已保存到钥匙串。留空时用默认域名，一样能用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Qwen-MT 是备用翻译：DeepSeek 挂了它顶上，平时不用。Key 只存手机钥匙串，不进代码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("记录") {
                    NavigationLink("历史记录") {
                        HistoryView()
                    }
                    NavigationLink("生词本") {
                        VocabView()
                    }
                }

                Section("DeepSeek 花费") {
                    if spend.requests == 0 {
                        Text("暂无 DeepSeek 使用记录。")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("调用次数")
                            Spacer()
                            Text("\(spend.requests) 次")
                        }
                        HStack {
                            Text("Token")
                            Spacer()
                            Text("\(spend.totalTokens)（输入 \(spend.promptTokens) / 输出 \(spend.completionTokens)）")
                        }
                        HStack {
                            Text("估算花费")
                            Spacer()
                            Text("约 ¥\(String(format: "%.2f", spend.costYuan))")
                        }
                        Text("按 DeepSeek 官网高峰价估算；闲时半价、缓存命中更便宜。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("偏好设置") {
                    Picker("语气", selection: $tone) {
                        ForEach(TranslationTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .onChange(of: tone) { _, value in
                        settings.translationTone = value
                    }
                    TextField("默认翻译语言", text: $language)
                        .onChange(of: language) { _, value in
                            settings.defaultTranslationLanguage = value
                        }
                }

                Section("帮助") {
                    Button {
                        showingGetStarted = true
                    } label: {
                        Label("新手引导", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("设置")
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
                qwenConfigured = await DashScopeStore.hasKey()
                dashScopeWorkspaceID = await DashScopeStore.loadWorkspaceID() ?? ""
                refreshProviderKeyStatus()
            }
            .onChange(of: showingModelPicker) { _, isShowing in
                if !isShowing { refreshProviderKeyStatus() }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var items: [TransformHistory]
    @State private var searchText = ""
    @State private var showingClearConfirm = false

    private var filtered: [TransformHistory] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.sourceExcerpt.localizedCaseInsensitiveContains(searchText)
                || $0.resultExcerpt.localizedCaseInsensitiveContains(searchText)
                || $0.providerName.localizedCaseInsensitiveContains(searchText)
                || $0.model.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    "没有历史记录",
                    systemImage: "clock",
                    description: Text(searchText.isEmpty ? "翻过的内容会记在这里。" : "没有匹配 “\(searchText)” 的记录。")
                )
            }
            ForEach(filtered) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.resultExcerpt)
                        .font(.body)
                    HStack(spacing: 0) {
                        Text(LocalizedStringKey(item.actionRawValue.capitalized))
                        Text(" · \(item.providerName) · \(item.model)")
                        if item.totalTokens > 0 {
                            Text(" · \(item.totalTokens) token")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for offset in offsets {
                    modelContext.delete(filtered[offset])
                }
                try? modelContext.save()
            }
        }
        .navigationTitle("历史记录")
        .searchable(text: $searchText, prompt: "搜索原文、译文或模型")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: HistoryExporter.text(for: filtered),
                    preview: SharePreview("历史记录", image: Image(systemName: "clock"))
                ) {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") {
                    showingClearConfirm = true
                }
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                for item in items { modelContext.delete(item) }
                try? modelContext.save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可恢复。")
        }
    }
}
