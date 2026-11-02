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
        let customSettings = model.jobs[0].resolvedSettings
        model.jobs[0].qualityProfile = .recommended
        let recommendedSettings = model.jobs[0].resolvedSettings
        precondition(recommendedSettings.noiseThreshold == 0.03)
        precondition(recommendedSettings.denoise && recommendedSettings.adaptive)
        precondition(recommendedSettings.samples == model.jobs[0].sourceSamples)
        precondition(recommendedSettings.adapterArguments.contains("0.03"))
        model.jobs[0].qualityProfile = .custom
        precondition(model.jobs[0].resolvedSettings == customSettings)
        model.startQueue()
        precondition(model.isRendering && !model.canStart)
        try await waitForCompletion(model)
        precondition(model.jobs[0].state == .finished, model.jobs[0].log)
        precondition((model.jobs[0].renderDuration ?? 0) > 0)
        precondition(model.jobs[0].log.contains("Total time (including preparation and denoise)"))
        let duration = model.jobs[0].elapsedRenderTime
        let completedSettings = model.jobs[0].lastRunSettings
        precondition(completedSettings == model.jobs[0].resolvedSettings)
        precondition(model.jobs[0].log.contains("adaptive sampling OFF, denoise OFF"))
        model.jobs[0].qualityProfile = .recommended
        precondition(model.jobs[0].lastRunSettings == completedSettings)
        precondition(model.jobs[0].resolvedSettings != completedSettings)
        model.jobs[0].qualityProfile = .custom
        try await Task.sleep(for: .milliseconds(200))
        precondition(model.jobs[0].elapsedRenderTime == duration)
        precondition(model.canStart, "Selected finished job must be renderable from toolbar")

        let firstOutput = model.jobs[0].outputURL
        let firstBytes = try Data(contentsOf: firstOutput)
        // Exercise disk and queued-job collisions without replacement dialogs.
        let occupied = directory.appendingPathComponent("result-001.png")
        try Data("existing-image".utf8).write(to: occupied)
        var reservedJob = RenderJob(inputURL: model.jobs[0].inputURL, manifest: nil)
        reservedJob.outputURL = directory.appendingPathComponent("result-002.png")
        reservedJob.state = .finished
        model.jobs.append(reservedJob)
        model.jobs[0].qualityProfile = .recommended
        model.startQueue()
        precondition(model.isRendering && model.jobs[0].renderDuration == nil)
        precondition(model.jobs[0].outputURL.lastPathComponent == "result-003.png")
        try await waitForCompletion(model)
        precondition(model.jobs[0].state == .finished, model.jobs[0].log)
        precondition(model.jobs[0].log.contains("adaptive sampling ON, denoise OIDN ON"))
        precondition(model.jobs[0].log.contains("Noise threshold 0.03"))
        precondition(model.jobs[0].lastRunSettings?.noiseThreshold == 0.03)
        precondition((model.jobs[0].renderDuration ?? 0) > 0)
        let preservedFirst = try Data(contentsOf: firstOutput)
        let preservedOccupied = try Data(contentsOf: occupied)
        precondition(preservedFirst == firstBytes)
        precondition(preservedOccupied == Data("existing-image".utf8))
        precondition(model.jobs[0].lastRunSettings?.outputURL == model.jobs[0].outputURL)
        print("PASS: indexed rerender skips disk/queue collisions, preserves images and settings/timing")

        model.startQueue()
        precondition(model.jobs[0].outputURL.lastPathComponent == "result-004.png")
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
