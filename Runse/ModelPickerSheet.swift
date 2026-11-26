import RunseCore
import SwiftData
import SwiftUI

/// Model picker, in the style of OpenChat's ModelPickerSheet (search and
/// favorites were left out for v1; the groups, the offline greying and
/// the keychain status are the parts that matter here).
struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderProfile.name) private var profiles: [ProviderProfile]

    @StateObject private var connectivity = ConnectivityMonitor()
    @State private var voiceConfigured = false
    @State private var qwenConfigured = false
    @State private var deepSeekConfigured = false
    @State private var searchText = ""

    private let settings = SettingsStore()

    var body: some View {
        NavigationStack {
            List {
                if !connectivity.isOnline {
                    Section {
                        Label("没有网络，云端模型不可选。", systemImage: "wifi.slash")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(ModelGroup.allCases) { group in
                    let options = filteredOptions(for: group)
                    if !options.isEmpty {
                        Section(group.title) {
                            ForEach(options) { option in
                                ModelOptionRow(
                                    option: option,
                                    isSelected: settings.selectedModelOptionID == option.id,
                                    isOnline: connectivity.isOnline
                                ) {
                                    apply(option)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索模型")
            .navigationTitle("选择模型")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                let config = await VolcanoVoiceStore.load()
                voiceConfigured = config != nil
                qwenConfigured = await DashScopeStore.hasKey()
                // S13: one DeepSeek key covers both DeepSeek options.
                // await may not sit on the right of ||, so each side
                // is awaited into a local first.
                let flashKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.defaultProfileID)
                let proKey = await ProviderKeyStore.hasKey(profileID: RunseConstants.deepSeekProProfileID)
                deepSeekConfigured = flashKey || proKey
            }
        }
    }

    private func filteredOptions(for group: ModelGroup) -> [ModelOption] {
        let options = ModelCatalog.options(voiceConfigured: voiceConfigured, qwenConfigured: qwenConfigured, deepSeekConfigured: deepSeekConfigured)
            .filter { $0.group == group }
        guard !searchText.isEmpty else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.detail.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func apply(_ option: ModelOption) {
        guard option.isSelectable else { return }
        if option.group != .local && option.group != .voice && !connectivity.isOnline { return }
        settings.selectedModelOptionID = option.id
        if let profileID = option.profileID {
            for profile in profiles {
                profile.isDefault = profile.id == profileID
            }
            try? modelContext.save()
        }
    }
}

struct ModelOptionRow: View {
    let option: ModelOption
    let isSelected: Bool
    let isOnline: Bool
    let onSelect: () -> Void

    private var isCloud: Bool {
        option.group == .cloudChina || option.group == .cloudOverseas
    }

    private var isDisabled: Bool {
        !option.isSelectable || (isCloud && !isOnline)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.name)
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let statusText = option.statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if isCloud && !isOnline {
                        Text("无网络，不可选")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .disabled(isDisabled)
    }
}
