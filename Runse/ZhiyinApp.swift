import RunseCore
import SwiftData
import SwiftUI

@main
struct ZhiyinApp: App {
    // Built synchronously in init (like before): a failed build must
    // show a recovery screen, never fatalError the app on launch.
    // The recovery button rebuilds through `rebuildAfterWipe()`.
    @State private var container: ModelContainer?
    @State private var containerError: String?

    init() {
        do {
            let created = try Self.openContainer()
            _container = State(initialValue: created)
            _containerError = State(initialValue: nil)
        } catch {
            _container = State(initialValue: nil)
            _containerError = State(initialValue: error.localizedDescription)
        }
    }

    /// Opens the container, backing the old database up and retrying
    /// with a fresh one when the first attempt fails (a corrupt
    /// sqlite file must not brick the app).
    private static func openContainer() throws -> ModelContainer {
        do {
            let created = try Bootstrap.modelContainer()
            Task { @MainActor in
                Self.seedOrRecord(context: created.mainContext)
            }
            return created
        } catch {
            let backupURL = try Bootstrap.backupDatabase()
            let created = try Bootstrap.modelContainer()
            Task { @MainActor in
                Self.seedOrRecord(context: created.mainContext)
            }
            // The backup is kept for the user; note it in the log
            // rather than surfacing a scary error.
            print("Zhiyin: database rebuilt, old copy kept at \(backupURL.path)")
            return created
        }
    }

    /// S25: seed the defaults, but never swallow a failure again.
    /// A failure is logged and recorded for Settings (see
    /// BootstrapSeedStatus); the next launch retries, because
    /// seeding is insert-only.
    @MainActor
    private static func seedOrRecord(context: ModelContext) {
        do {
            try Bootstrap.seedDefaultsIfNeeded(context: context)
            BootstrapSeedStatus.clear()
        } catch {
            print("Zhiyin: seeding defaults failed: \(error)")
            BootstrapSeedStatus.record(error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container {
                    ContentView()
                        .modelContainer(container)
                } else if let containerError {
                    DatabaseRecoveryView(errorMessage: containerError) {
                        rebuildAfterWipe()
                    }
                } else {
                    ProgressView("正在打开数据库…")
                }
            }
        }
    }

    /// The recovery screen's "清除并重建" action: delete the database
    /// files outright (after one more backup attempt) and try again.
    private func rebuildAfterWipe() {
        containerError = nil
        do {
            _ = try? Bootstrap.backupDatabase()
            try Bootstrap.deleteDatabaseFiles()
            container = try Self.openContainer()
        } catch {
            containerError = error.localizedDescription
        }
    }
}

/// Shown instead of the main UI when the database cannot be opened
/// even after a backup-and-rebuild attempt. Nothing here deletes
/// data silently: the button rebuilds an empty database, and the old
/// copy stays in Application Support under Zhiyin/Backups.
private struct DatabaseRecoveryView: View {
    var errorMessage: String
    var onRebuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("数据库打不开")
                .font(.title2.bold())
            Text("智音的本地数据库损坏或无法打开，旧数据已备份，没有丢失。点下面重建一个空数据库就能继续用。")
                .foregroundStyle(.secondary)
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("清除并重建数据库", action: onRebuild)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}
