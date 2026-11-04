import AppKit

@MainActor
enum BrowserExtensionSetup {
    static func install() {
        do {
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let extensionFolder = resources.appendingPathComponent("ChromiumExtension", isDirectory: true)
            let identifier = try BrowserExtensionIdentity.identifier(manifest: extensionFolder.appendingPathComponent("manifest.json"))
            let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/DropViewRenderNativeHost")
            guard FileManager.default.isExecutableFile(atPath: host.path) else { throw CocoaError(.fileNoSuchFile) }
            let confirm = NSAlert()
            confirm.messageText = "Set Up Chrome / Edge"
            confirm.informativeText = "Register this app’s native messaging helper for Chrome and Edge for your macOS user. Then load the bundled extension in the browser. Keep this app in a stable location; repeat setup if you move it. Safari settings are separate."
            confirm.addButton(withTitle: "Register and Show Extension")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            let manifest: [String: Any] = ["name": "com.hildgyorgy.DropViewRender".lowercased(),
                "description": "Drop & View Render", "path": host.path, "type": "stdio",
                "allowed_origins": ["chrome-extension://\(identifier)/"]]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let browsers = [("com.google.Chrome", "Google/Chrome"), ("com.microsoft.edgemac", "Microsoft Edge")]
                .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
            guard !browsers.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            for (_, browser) in browsers {
                let folder = support.appendingPathComponent(browser).appendingPathComponent("NativeMessagingHosts")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("com.hildgyorgy.dropviewrender.json"), options: .atomic)
            }
            NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Chrome / Edge Setup Failed"
            alert.informativeText = error.localizedDescription + "\n" + String(describing: error as NSError)
            alert.runModal()
        }
    }
}
