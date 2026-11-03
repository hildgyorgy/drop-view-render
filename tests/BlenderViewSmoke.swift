// Compile into a temporary .app containing adapter resources; pass a GLB.
import Foundation

@main
struct BlenderViewSmoke {
    @MainActor
    static func main() async throws {
        let model = RenderQueueModel()
        model.add([URL(fileURLWithPath: CommandLine.arguments[1])])
        let id = model.jobs[0].id
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("view-test-\(UUID()).png")
        model.jobs[0].outputURL = png
        model.jobs[0].overridesResolution = true
        model.jobs[0].width = 64
        model.jobs[0].height = 64
        model.jobs[0].qualityProfile = .custom
        model.jobs[0].samples = 2
        let settings = model.jobs[0].resolvedSettings
        model.jobs[0].lastRunSettings = settings
        model.jobs[0].samples = 7
        var opened: [URL] = []
        model.blenderSceneOpener = { scene, executable in
            precondition(executable == model.blender.executableURL)
            precondition(FileManager.default.fileExists(atPath: scene.path))
            opened.append(scene)
        }
        model.viewInBlender(id)
        precondition(model.preparingBlenderJobID == id && !model.isRendering && !model.canStart)
        model.remove(id)
        precondition(model.jobs.count == 1)
        model.viewInBlender(id) // duplicate click cannot spawn a second preparation
        try await wait(model)
        precondition(opened.count == 1, model.jobs[0].blenderViewError ?? "No scene opened")
        precondition(model.jobs[0].state == .queued && model.jobs[0].lastRunSettings == settings)
        precondition(!FileManager.default.fileExists(atPath: png.path))
        let handle = try FileHandle(forReadingFrom: opened[0])
        let header = try handle.read(upToCount: 7)
        try handle.close()
        precondition(header == Data("BLENDER".utf8))
        model.viewInBlender(id)
        var terminated = false
        model.stopForApplicationTermination { terminated = true }
        try await wait(model)
        precondition(terminated && opened.count == 1)
        print("PASS: native scene preparation, unchanged job/PNG, duplicate guard, quit cancellation")
        print("Prepared scene: \(opened[0].path)")
    }

    @MainActor
    static func wait(_ model: RenderQueueModel) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while model.preparingBlenderJobID != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(model.preparingBlenderJobID == nil, "Scene preparation timed out")
    }
}
