import RunseCore
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ActionViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let selectedText = await loadText()
            // N13: the old code silently fell back to a throwaway
            // in-memory database when the shared container would not
            // open (and the fallback itself was a `try!` crash risk),
            // so the user "saved" history that vanished with the
            // extension. Show an error instead of pretending success.
            do {
                let container = try Bootstrap.modelContainer()
                try? Bootstrap.seedDefaultsIfNeeded(context: container.mainContext)
                showRoot(container: container, selectedText: selectedText)
            } catch {
                showDatabaseError(error)
            }
        }
    }

    private func showRoot(container: ModelContainer, selectedText: String) {
        let root = ExtensionRootView(selectedText: selectedText) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
        .modelContainer(container)
        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    private func showDatabaseError(_ error: Error) {
        let label = UILabel()
        label.text = "数据库打不开，请先打开主 App 一次再试。\n\(error.localizedDescription)"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func loadText() async -> String {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            return ""
        }
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let text = value as? String { return text }
                if let url = value as? URL, let text = try? String(contentsOf: url) { return text }
                if let data = value as? Data, let text = String(data: data, encoding: .utf8) { return text }
            }
        }
        return ""
    }
}

