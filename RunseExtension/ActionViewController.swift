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
            let container = (try? Bootstrap.modelContainer()) ?? (try! Bootstrap.modelContainer(inMemory: true))
            try? Bootstrap.seedDefaultsIfNeeded(context: container.mainContext)
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

