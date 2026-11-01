import AppKit
import Foundation

struct BlenderInstallation {
    let executableURL: URL?
    let title: String
    let detail: String

    static let missing = BlenderInstallation(
        executableURL: nil,
        title: "Blender not found",
        detail: "Install Blender 5.2.3 LTS or choose its executable."
    )
}

enum BlenderLocator {
    private static let storedPathKey = "DropViewRender.BlenderExecutablePath"

    static func discover() -> BlenderInstallation {
        let storedPath = UserDefaults.standard.string(forKey: storedPathKey)
        let candidates = [
            storedPath,
            "/Applications/Blender.app/Contents/MacOS/Blender",
            "/Applications/Blender 5.2.app/Contents/MacOS/Blender"
        ].compactMap { $0 }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return installation(at: URL(fileURLWithPath: path))
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
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .missing
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
}
