import RunseCore
import SwiftData
import SwiftUI

/// Item 13 (UI redesign): the document page hides the floating pill
/// nav (and its bottom inset) so the document gets the full screen.
/// PDFView flips this on appear / off on disappear.
final class PillNavState: ObservableObject {
    @Published var isHidden = false
}

struct ContentView: View {
    @State private var selection: Tab = .translate
    @State private var showingGetStarted = false
    @StateObject private var pillNavState = PillNavState()
    private let settings = SettingsStore()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Item 1 (UI redesign): the system tab bar is gone — a
            // floating pill switches between 翻译 / 相机 / 对话.
            // TabView stays underneath so each page keeps its state
            // and its onDisappear cleanup when you leave it.
            TabView(selection: $selection) {
                TranslateView()
                    .tag(Tab.translate)
                LiveCameraView()
                    .tag(Tab.camera)
                FaceToFaceView()
                    .tag(Tab.conversation)
            }
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Item 13: the document page hides the pill, so the
                // inset collapses with it and the document gets the
                // full height.
                Color.clear.frame(height: pillNavState.isHidden ? 0 : 76)
            }

            if !pillNavState.isHidden {
                pillNav
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .environmentObject(pillNavState)
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

    /// Floating pill nav: 翻译 / 相机 / 对话.
    ///
    /// Item 16 (UI redesign): the conversation tab is the real-time
    /// translation entry (face-to-face, 20:53 — no separate entry),
    /// so it uses the two-people icon the boss sent (light-blue
    /// circle, two people + mic, 21:07), drawn here as the
    /// two-people glyph to match the approved web preview — the
    /// image file itself is not in the workspace. The icon is one
    /// size bigger than the other two tabs ("做大一圈", 21:51 /
    /// preview: 33px vs 24px) and its slot is a touch wider.
    /// There is no separate interpretation icon: 同传 merged into
    /// the conversation page as continuous mode, and the boss's
    /// correction superseded "make the interpretation icon bigger"
    /// with "make the conversation icon bigger" instead.
    private var pillNav: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: tab.iconSize, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(selection == tab ? .white : .primary)
                    .background(
                        Capsule().fill(selection == tab ? Color.green : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .layoutPriority(tab == .conversation ? 1 : 0)
            }
        }
        .padding(6)
        .liquidGlass(in: Capsule())
        .overlay {
            Capsule().stroke(Color.secondary.opacity(0.15))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    enum Tab: CaseIterable, Hashable {
        case translate, camera, conversation

        var title: String {
            switch self {
            case .translate: "翻译"
            case .camera: "相机"
            case .conversation: "对话"
            }
        }

        var icon: String {
            switch self {
            case .translate: "text.badge.checkmark"
            case .camera: "camera"
            case .conversation: "person.2.fill"
            }
        }

        /// Item 16: the conversation icon is one size bigger
        /// ("做大一圈") — 28pt vs 20pt, same ratio as the approved
        /// web preview (33px vs 24px).
        var iconSize: CGFloat {
            switch self {
            case .conversation: 28
            case .translate, .camera: 20
            }
        }
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
    @State private var tone = SettingsStore().translationTone
    @State private var showingGetStarted = false
    @State private var showingModelPicker = false
    @State private var voiceConfigured = false
    @State private var qwenConfigured = false
    /// S13: whether either DeepSeek profile has a key (one key
    /// covers both DeepSeek options).
    @State private var deepSeekConfigured = false
    /// S12: manual balance update — there is no console API to
    /// query the balance, so the user types the figure from the
    /// voice console and it is shown with its date.
    @State private var balanceInput = ""
    @State private var balanceSaved = false
    @State private var dashScopeKey = ""
    @State private var dashScopeSaved = false
    @State private var dashScopeError: String?
    @State private var dashScopeWorkspaceID = ""
    @State private var workspaceSaved = false
    @State private var providerKey = ""
    @State private var providerKeyConfigured = false
    @State private var providerKeySaved = false
    @State private var providerKeyError: String?
    /// Item 14 (UI redesign): voice choice / speed / my voice live
    /// in Settings now (the old voice tab is gone) — same
    /// VoiceSettings store as the voice page used, so both stay in
    /// sync. hasMyVoice gates the "use my voice" toggle.
    @State private var speakerID = VoiceSettings().speakerID
    @State private var speechRate = VoiceSettings().speechRate
    @State private var useMyVoice = VoiceSettings().useMyVoice
    @State private var hasMyVoice = false
    /// S6: a keychain read fault is not "not configured" — when set,
    /// the settings page says so instead of showing 未配置.
    @State private var keychainReadError: String?
    /// S25: a recorded seeding failure, shown at the top of Settings
    /// with a manual retry instead of leaving every screen to report
    /// missing Key / invalid URL.
    @State private var seedFailure: (message: String, date: Date)?
    @State private var seedRetryMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransformHistory.timestamp, order: .reverse) private var historyItems: [TransformHistory]
    private let settings = SettingsStore()

    private var currentModelName: String {
        ModelCatalog.option(id: settings.selectedModelOptionID, voiceConfigured: voiceConfigured, qwenConfigured: qwenConfigured, deepSeekConfigured: deepSeekConfigured)?.name
            ?? "DeepSeek 日常"
    }

    /// SwiftData profile id backing the currently selected model option.
    /// Qwen-MT options use the DashScope key (see the Qwen-MT section
    /// below); every other profile uses its own key under
    /// `Zhiyin.ProviderAPIKey` (M1).
    private var currentProfileID: String? {
        ModelCatalog.option(id: settings.selectedModelOptionID, voiceConfigured: voiceConfigured, qwenConfigured: qwenConfigured, deepSeekConfigured: deepSeekConfigured)?.profileID
    }

    private var isCurrentModelQwenMT: Bool {
        guard let id = currentProfileID else { return false }
        return id == QwenMT.flashProfileID || id == QwenMT.plusProfileID
    }

    /// The profile id the API Key row saves under: the current
    /// non-Qwen profile, or the default DeepSeek profile when
    /// Qwen-MT is selected but no DeepSeek key exists yet. Without
    /// the second case the picker could never switch back to
    /// DeepSeek — needsKey options are not selectable, and the key
    /// row would be hidden behind the Qwen selection.
    private var apiKeyProfileID: String? {
        if let profileID = currentProfileID, !isCurrentModelQwenMT {
            return profileID
        }
        if !deepSeekConfigured {
            return RunseConstants.defaultProfileID
        }
        return nil
    }

    private func refreshProviderKeyStatus() {
        Task {
            // S13: keep the DeepSeek status in sync when the picker
            // closes (a key may have just been saved for it).
            // await may not sit on the right of ||, so each side
            // is awaited into a local first.
            let flashKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.defaultProfileID)
            let proKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.deepSeekProProfileID)
            deepSeekConfigured = flashKey || proKey
            if let profileID = apiKeyProfileID {
                do {
                    providerKeyConfigured = try await ProviderKeyStore.loadKeyThrowing(profileID: profileID) != nil
                    keychainReadError = nil
                } catch {
                    // S6: a keychain fault is not "not configured".
                    providerKeyConfigured = false
                    keychainReadError = "钥匙串读取失败：\(error.localizedDescription)"
                }
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
                // S25: a failed first-launch seeding used to surface
                // only as "Key 未配置 / 地址无效" on every screen.
                if let seedFailure {
                    Section("初始化失败") {
                        Text("启动时没能写入默认模型和模板（\(seedFailure.date.formatted(date: .abbreviated, time: .shortened))），各页面可能报 Key 未配置或地址无效。下次启动会自动再试，也可以现在重试。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Text(seedFailure.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("重试初始化") {
                            Task { @MainActor in
                                do {
                                    try Bootstrap.seedDefaultsIfNeeded(context: modelContext)
                                    BootstrapSeedStatus.clear()
                                    self.seedFailure = nil
                                    seedRetryMessage = "初始化成功，默认模型和模板已补齐。"
                                } catch {
                                    BootstrapSeedStatus.record(error.localizedDescription)
                                    self.seedFailure = BootstrapSeedStatus.load()
                                    seedRetryMessage = nil
                                }
                            }
                        }
                        if let seedRetryMessage {
                            Text(seedRetryMessage)
                                .font(.footnote)
                                .foregroundStyle(.green)
                        }
                    }
                }
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
                    }
                    if let profileID = apiKeyProfileID {
                        HStack {
                            Text("API Key")
                            Spacer()
                            Text(providerKeyConfigured ? "已配置" : "未配置")
                                .foregroundStyle(providerKeyConfigured ? .green : .orange)
                        }
                        SecureField(profileID == currentProfileID ? "粘贴当前模型的 API Key" : "粘贴 DeepSeek API Key（切回 DeepSeek 时用）", text: $providerKey)
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
                        if let keychainReadError {
                            Text(keychainReadError)
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
                    if let keychainReadError {
                        Text(keychainReadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if !voiceConfigured {
                        Text("去“语音”页填 AppID 和 Access Token（只存钥匙串）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // S12: the balance has no query API — update it by
                    // hand from the voice console; the interpretation
                    // page shows it with the date it was entered.
                    HStack {
                        Text("账户余额（元）")
                        TextField("如 2.36", text: $balanceInput)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Button("保存") {
                            if let value = Double(balanceInput.trimmingCharacters(in: .whitespaces)) {
                                InterpretationQuotaStore().setBalance(value)
                                balanceSaved = true
                                balanceInput = ""
                            }
                        }
                        .disabled(Double(balanceInput.trimmingCharacters(in: .whitespaces)) == nil)
                    }
                    if balanceSaved {
                        Text("余额已更新，同传页会显示这个数和今天的日期。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("声音") {
                    Picker("声音", selection: $speakerID) {
                        Section("女声") {
                            ForEach(DoubaoSpeaker.all.filter { $0.gender == .female }) { speaker in
                                Text(speaker.name).tag(speaker.id)
                            }
                        }
                        Section("男声") {
                            ForEach(DoubaoSpeaker.all.filter { $0.gender == .male }) { speaker in
                                Text(speaker.name).tag(speaker.id)
                            }
                        }
                    }
                    .onChange(of: speakerID) { _, value in
                        var settings = VoiceSettings()
                        settings.speakerID = value
                    }
                    HStack {
                        Text("语速")
                        Slider(value: $speechRate, in: 0.5...2.0, step: 0.05)
                            .onChange(of: speechRate) { _, value in
                                var settings = VoiceSettings()
                                settings.speechRate = value
                            }
                        Text("×\(String(format: "%.2f", speechRate))")
                            .monospacedDigit()
                    }
                }

                Section("我的声音") {
                    NavigationLink("我的声音") {
                        MyVoiceView()
                    }
                    Toggle("用我的声音朗读", isOn: $useMyVoice)
                        .disabled(!hasMyVoice)
                        .onChange(of: useMyVoice) { _, value in
                            var settings = VoiceSettings()
                            settings.useMyVoice = value
                        }
                    if !hasMyVoice {
                        Text("录 10–30 秒就能复刻自己的声音。")
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
                    if let keychainReadError {
                        Text(keychainReadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
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
                    // S18: a mistyped workspace ID had no way back —
                    // add a clear path (back to the default domain).
                    Button("清除业务空间 ID", role: .destructive) {
                        Task {
                            do {
                                try await DashScopeStore.clearWorkspaceID()
                                dashScopeWorkspaceID = ""
                                workspaceSaved = false
                            } catch {
                                dashScopeError = "清除失败：\(error.localizedDescription)"
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
                    // Item 14: glossary lives in Settings now. The
                    // editor shows the stored entries; candidates
                    // (terms extracted from input text) only come from
                    // the translate page, so here it is an empty list.
                    NavigationLink("术语表") {
                        GlossaryEditorView(candidates: [])
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
                    // S16: the "默认翻译语言" free-text field was
                    // removed — no screen ever read it (every
                    // translation passes its target explicitly, and
                    // PromptContext defaults to the constant), so
                    // typing in it silently did nothing.
                }

                Section("帮助") {
                    Button {
                        showingGetStarted = true
                    } label: {
                        Label("新手引导", systemImage: "questionmark.circle")
                    }
                }
            }
            // Item 14 (UI redesign): card-style Settings, Apple
            // style — rounded inset-grouped cards.
            .listStyle(.insetGrouped)
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
                // Item 14: whether a cloned voice exists gates the
                // "use my voice" toggle.
                hasMyVoice = await QwenVoiceStore.loadVoiceID() != nil
                // S25: surface a recorded seeding failure, if any.
                seedFailure = BootstrapSeedStatus.load()
                // S6: throwing loads — a keychain fault must surface
                // as a read failure, not as "not configured".
                do {
                    voiceConfigured = try await VolcanoVoiceStore.loadThrowing() != nil
                } catch {
                    voiceConfigured = false
                    keychainReadError = "钥匙串读取失败：\(error.localizedDescription)"
                }
                do {
                    qwenConfigured = try await DashScopeStore.loadKeyThrowing() != nil
                } catch {
                    qwenConfigured = false
                    keychainReadError = "钥匙串读取失败：\(error.localizedDescription)"
                }
                // S13: one DeepSeek key covers both DeepSeek options.
                // await may not sit on the right of ||, so each side
                // is awaited into a local first.
                let flashKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.defaultProfileID)
                let proKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.deepSeekProProfileID)
                deepSeekConfigured = flashKey || proKey
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
