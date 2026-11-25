import RunseCore
import SwiftData
import SwiftUI

@main
struct ZhiyinApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try Bootstrap.modelContainer()
            let modelContainer = container
            Task { @MainActor in
                try? Bootstrap.seedDefaultsIfNeeded(context: modelContainer.mainContext)
            }
        } catch {
            fatalError("Unable to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
