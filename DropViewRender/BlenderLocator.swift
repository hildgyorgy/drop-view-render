import AppKit
import Foundation

struct BlenderInstallation {
    let executableURL: URL?
    let title: String
    let detail: String

    static let missing = BlenderInstallation(
        executableURL: nil,
        title: "Blender not found",
        detail: "Install Blender 5.3.0 or choose its executable."
    )
}

enum BlenderLocator {
    private static let storedPathKey = "DropViewRender.BlenderExecutablePath"

    static func discover() -> BlenderInstallation {
        let storedPath = UserDefaults.standard.string(forKey: storedPathKey)
        let candidates = [
            storedPath,
            "/Applications/Blender 5.3.app/Contents/MacOS/Blender",
            "/Applications/Blender 5.3.0.app/Contents/MacOS/Blender",
            "/Applications/Blender.app/Contents/MacOS/Blender",
            "/Applications/Blender 5.2.app/Contents/MacOS/Blender"
        ].compactMap { $0 }

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if isValidExecutable(url) { return installation(at: url) }
        }
        return .missing
    }

    static func choose() -> BlenderInstallation? {
        let panel = NSOpenPanel()
        panel.title = "Choose the Blender executable"
        panel.message = "Choose Blender.app, or Contents/MacOS/Blender inside the application bundle."
        panel.prompt = "Choose Blender"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        let executable = chosen.pathExtension == "app"
            ? chosen.appendingPathComponent("Contents/MacOS/Blender")
            : chosen
        guard isValidExecutable(executable) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That is not a Blender executable"
            alert.informativeText = "Choose Blender.app or its Contents/MacOS/Blender executable."
            alert.runModal()
            return nil
        }
        UserDefaults.standard.set(executable.path, forKey: storedPathKey)
        return installation(at: executable)
    }

    private static func installation(at executable: URL) -> BlenderInstallation {
        BlenderInstallation(
            executableURL: executable,
            title: "Blender ready",
            detail: executable.path
        )
    }

    private static func isValidExecutable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
            && FileManager.default.isExecutableFile(atPath: url.path)
            && url.lastPathComponent == "Blender"
    }
}
