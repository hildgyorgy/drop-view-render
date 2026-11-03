// Compile in a temporary .app with the adapter resources; pass a real .dvrender.
import Foundation

@main
struct BrowserRenderSmoke {
    @MainActor
    static func main() async throws {
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let manifestLength = fixture[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var manifest = try JSONSerialization.jsonObject(with: fixture[12..<12 + manifestLength]) as! [String: Any]
        // Explicit test fixture settings; never change production requested quality.
        manifest["renderSize"] = ["width": 64, "height": 64]
        manifest["renderJob"] = ["samples": 2, "bounces": 6, "transmissiveBounces": 10]
        let json = try JSONSerialization.data(withJSONObject: manifest)
        var length = UInt32(json.count).littleEndian
        var package = Data("DVRENDER".utf8)
        withUnsafeBytes(of: &length) { package.append(contentsOf: $0) }
        package.append(json)
        package.append(fixture[(12 + manifestLength)...])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-render-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.dvrender")
        try package.write(to: source)
        let model = RenderQueueModel()
        model.add([source]) // must remain queued throughout browser render
        let unrelated = model.jobs[0].id
        let bridge = BrowserBridge()
        bridge.outputDirectory = root
        bridge.approvePairing = { _, finish in finish(true) }
        bridge.rendererStatus = { ["blenderAvailable": model.blender.executableURL != nil, "rendering": model.isRendering] }
        bridge.submitJob = { try model.acceptBrowserJob(at: $0, manifest: $1, outputDirectory: $2) }
        bridge.jobStatus = { model.browserJobStatus($0) }
        bridge.cancelJob = { model.cancelBrowserJob($0) }
        bridge.start()
        defer { bridge.stop() }
        try await Task.sleep(for: .milliseconds(300))
        precondition(bridge.status.hasPrefix("Browser bridge: 127.0.0.1:"), bridge.status)
        let origin = "http://localhost:4173"
        var token: String?
        func request(_ path: String, _ method: String = "GET", body: Data? = nil,
                     headers: [String: String] = [:]) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:43127/v1/\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 60
            request.httpBody = body
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:])
        }
        token = try await request("pair", "POST").1["token"] as? String
        precondition(token != nil)
        var headers = ["Content-Type": "application/octet-stream", "Idempotency-Key": UUID().uuidString,
                       "X-DVR-Settings": "{\"version\":1,\"profile\":\"recommended\"}"]
        let invalid = try await request("jobs", "POST", body: Data(repeating: 1, count: 4096), headers: headers)
        precondition(invalid.0 == 400 && model.jobs.count == 1)
        headers["Idempotency-Key"] = UUID().uuidString
        let accepted = try await request("jobs", "POST", body: package, headers: headers)
        precondition(accepted.0 == 202, "\(accepted)")
        let id = accepted.1["id"] as! String
        precondition(model.jobs.count == 2)
        let duplicate = try await request("jobs", "POST", body: package, headers: headers)
        precondition(duplicate.0 == 202 && duplicate.1["id"] as? String == id && model.jobs.count == 2)
        var changed = package
        changed[changed.count - 1] ^= 1
        let conflict = try await request("jobs", "POST", body: changed, headers: headers)
        precondition(conflict.0 == 409 && model.jobs.count == 2)
        try await waitForRender(model)
        let completed = try await request("jobs/\(id)")
        precondition(completed.0 == 200 && completed.1["state"] as? String == "finished", "\(completed)\n\(model.jobs.last!.log)")
        precondition(model.jobs.first(where: { $0.id == unrelated })?.state == .queued)
        precondition(model.jobs.last?.lastRunSettings?.samples == 2)
        precondition(model.jobs.last?.lastRunSettings?.noiseThreshold == 0.03)
        let firstImage = model.jobs.last!.outputURL
        let imageBytes = try Data(contentsOf: firstImage)
        precondition(!imageBytes.isEmpty)
        headers["Idempotency-Key"] = UUID().uuidString
        let second = try await request("jobs", "POST", body: package, headers: headers)
        precondition(second.0 == 202)
        let secondID = second.1["id"] as! String
        precondition(model.jobs.last!.outputURL != firstImage)
        headers["Idempotency-Key"] = UUID().uuidString
        let queued = try await request("jobs", "POST", body: package, headers: headers)
        precondition(queued.0 == 202)
        let queuedID = queued.1["id"] as! String
        let waiting = try await request("jobs/\(queuedID)")
        precondition(waiting.1["state"] as? String == "queued", "\(waiting)")
        precondition(waiting.1["queuePosition"] as? Int == 1)
        let queuedIndex = model.jobs.firstIndex(where: { $0.id.uuidString == queuedID })!
        // Native next-render edits must not mutate an already submitted snapshot.
        model.jobs[queuedIndex].overridesResolution = true
        model.jobs[queuedIndex].width = 8
        model.jobs[queuedIndex].qualityProfile = .custom
        model.jobs[queuedIndex].samples = 1
        headers["Idempotency-Key"] = UUID().uuidString
        let toRemove = try await request("jobs", "POST", body: package, headers: headers)
        let removedID = toRemove.1["id"] as! String
        let cancelWaiting = try await request("jobs/\(removedID)/cancel", "POST")
        precondition(cancelWaiting.0 == 200)
        precondition(model.jobs.last?.state == .cancelled)
        let cancelled = try await request("jobs/\(secondID)/cancel", "POST")
        precondition(cancelled.0 == 200)
        try await waitForRender(model)
        let activeCancelled = model.jobs.first(where: { $0.id.uuidString == secondID })!
        precondition(activeCancelled.state == .cancelled, activeCancelled.log)
        let afterQueued = model.jobs.first(where: { $0.id.uuidString == queuedID })!
        precondition(afterQueued.state == .finished, afterQueued.log)
        precondition(afterQueued.lastRunSettings?.width == 64)
        precondition(afterQueued.lastRunSettings?.samples == 2)
        precondition(afterQueued.lastRunSettings?.denoise == true)
        precondition(model.jobs.first(where: { $0.id == unrelated })?.state == .queued)
        let preserved = try Data(contentsOf: firstImage)
        precondition(preserved == imageBytes)
        precondition(!FileManager.default.fileExists(atPath: activeCancelled.outputURL.path))
        let orphan = UUID().uuidString
        let denied = try await request("jobs/\(orphan)/cancel", "POST")
        precondition(denied.0 == 404)
        print("PASS: real Cycles upload → render → status; idempotent replay/conflict; indexed output; active/queued cancel; serial browser queue; immutable settings; unrelated queue preserved.")
        print("Temporary output: \(root.path)")
    }

    @MainActor
    static func waitForRender(_ model: RenderQueueModel) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while model.isRendering && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        precondition(!model.isRendering, "Render timed out")
    }
}
