import Foundation
import SwiftData

public enum Bootstrap {
    public static func modelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([ProviderProfile.self, PromptTemplate.self, TransformHistory.self, GlossaryEntry.self, InterpretationSession.self, InterpretationSegmentRecord.self, VocabularyEntry.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RunseConstants.appGroupID) {
            configuration = ModelConfiguration(url: groupURL.appending(path: "Zhiyin.sqlite"))
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor public static func seedDefaultsIfNeeded(context: ModelContext) throws {
        let defaultProfileID = RunseConstants.defaultProfileID
        var providerDescriptor = FetchDescriptor<ProviderProfile>(predicate: #Predicate { $0.id == defaultProfileID })
        providerDescriptor.fetchLimit = 1
        let defaultProvider = ProviderProfile.defaultDeepSeek()
        if let existingProvider = try context.fetch(providerDescriptor).first {
            existingProvider.name = defaultProvider.name
            existingProvider.kind = defaultProvider.kind
            existingProvider.baseURL = defaultProvider.baseURL
            existingProvider.chatEndpoint = defaultProvider.chatEndpoint
            existingProvider.model = defaultProvider.model
            existingProvider.extraHeadersJSON = defaultProvider.extraHeadersJSON
            existingProvider.isDefault = true
            existingProvider.updatedAt = .now
        } else {
            context.insert(defaultProvider)
        }

        // Precision-flip preset for long-form translation. Inserted once if
        // missing; never overwritten, so a user-edited copy is left alone.
        let proProfileID = RunseConstants.deepSeekProProfileID
        var proDescriptor = FetchDescriptor<ProviderProfile>(predicate: #Predicate { $0.id == proProfileID })
        proDescriptor.fetchLimit = 1
        if try context.fetch(proDescriptor).first == nil {
            context.insert(ProviderProfile.defaultDeepSeekPro())
        }

        // Qwen-MT backup profiles (清单 2). Inserted once if missing;
        // never overwritten. They only become active when the user saves
        // a DashScope key in Settings.
        for factory in [ProviderProfile.qwenMTFlash, ProviderProfile.qwenMTPlus] {
            let qwenProfile = factory()
            let qwenID = qwenProfile.id
            var qwenDescriptor = FetchDescriptor<ProviderProfile>(predicate: #Predicate { $0.id == qwenID })
            qwenDescriptor.fetchLimit = 1
            if try context.fetch(qwenDescriptor).first == nil {
                context.insert(qwenProfile)
            }
        }

        for template in PromptTemplate.builtIns() {
            let templateID = template.id
            var descriptor = FetchDescriptor<PromptTemplate>(predicate: #Predicate { $0.id == templateID })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                if existing.isBuiltIn {
                    existing.name = template.name
                    existing.action = template.action
                    existing.systemTemplate = template.systemTemplate
                    existing.userTemplate = template.userTemplate
                    existing.updatedAt = .now
                }
            } else {
                context.insert(template)
            }
        }
        try context.save()
    }
}

public enum TextExcerpt {
    public static func make(_ text: String, maxLength: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }
}
