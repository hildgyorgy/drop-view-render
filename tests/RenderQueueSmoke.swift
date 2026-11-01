// Compile with the model sources into a temporary .app with render_glb.py and
// backdrop.hdr in Contents/Resources. Pass a GLB path. Requires local Blender.
import Foundation

@main
struct RenderQueueSmoke {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-view-queue-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let model = RenderQueueModel()
        model.add([URL(fileURLWithPath: CommandLine.arguments[1])])
        precondition(model.jobs.count == 1 && model.jobs[0].isInputValid)
        model.jobs[0].outputURL = directory.appendingPathComponent("result.png")
        model.jobs[0].overridesResolution = true
        model.jobs[0].width = 64
        model.jobs[0].height = 64
        model.jobs[0].qualityProfile = .custom
        model.jobs[0].samples = 1
        model.jobs[0].usesDenoising = false
        model.jobs[0].usesAdaptiveSampling = false
        precondition(model.jobs[0].elapsedRenderTime == nil && model.canStart)
        model.startQueue()
        precondition(model.isRendering && !model.canStart)
        try await waitForCompletion(model)
        precondition(model.jobs[0].state == .finished, model.jobs[0].log)
        precondition((model.jobs[0].renderDuration ?? 0) > 0)
        precondition(model.jobs[0].log.contains("Total time (including preparation and denoise)"))
        let duration = model.jobs[0].elapsedRenderTime
        try await Task.sleep(for: .milliseconds(200))
        precondition(model.jobs[0].elapsedRenderTime == duration)
        precondition(model.canStart, "Selected finished job must be renderable from toolbar")

        // Simulate replacement already approved via the save panel. Only this
        // test-owned temporary output is replaced; production prompts otherwise.
        model.jobs[0].overwriteApproved = true
        model.startQueue()
        precondition(model.isRendering && model.jobs[0].renderDuration == nil)
        try await waitForCompletion(model)
        precondition(model.jobs[0].state == .finished, model.jobs[0].log)
        precondition((model.jobs[0].renderDuration ?? 0) > 0)
        print("PASS: toolbar first render/rerender, atomic replacement, live/frozen/reset timing")

        model.jobs[0].overwriteApproved = true
        model.startQueue()
        model.cancelRender()
        try await waitForCompletion(model)
        precondition(model.jobs[0].state == .cancelled, model.jobs[0].log)
        precondition(model.jobs[0].renderDuration != nil)
        print("PASS: cancellation retains elapsed time")
        print("Temporary test output: \(directory.path)")
    }

    @MainActor
    static func waitForCompletion(_ model: RenderQueueModel) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while model.isRendering && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(!model.isRendering, "Smoke render timed out")
    }
}
