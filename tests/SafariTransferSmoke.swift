// Compile with the native model/HTTP bridge and all Safari Swift sources.
// A real .dvrender fixture is streamed; test-only tiny render targets are explicit.
import Foundation
import CryptoKit

@main
struct SafariTransferSmoke {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dvr-safari-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SafariUploadStore(root: root.appendingPathComponent("uploads"))
        let router = SafariNativeRouter(store: store)
        let model = RenderQueueModel()
        let bridge = BrowserBridge()
        bridge.approvePairing = { _, finish in finish(true) }
        bridge.outputDirectory = root.appendingPathComponent("output")
        bridge.rendererStatus = { ["blenderAvailable": model.blender.executableURL != nil, "rendering": model.isRendering] }
        bridge.submitJob = { url, manifest, output in try model.acceptBrowserJob(at: url, manifest: manifest, outputDirectory: output) }
        bridge.jobStatus = { model.browserJobStatus($0) }
        bridge.cancelJob = { model.cancelBrowserJob($0) }
        bridge.start()
        defer { bridge.stop() }
        try await Task.sleep(for: .milliseconds(300))
        precondition(bridge.status.hasPrefix("Browser bridge: 127.0.0.1:"), bridge.status)

        let page = "https://hildgyorgy.github.io/drop-3d-view/"
        var token: String?
        func request(_ operation: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
            var message: [String: Any] = ["protocolVersion": 1, "id": UUID().uuidString,
                                          "operation": operation, "pageURL": page]
            if let token { message["token"] = token }
            message.merge(fields) { _, new in new }
            let result = await router.handle(message)
            guard result["ok"] as? Bool == true, let data = result["data"] as? [String: Any] else {
                throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(operation): \(result)"])
            }
            return data
        }
        token = try await request("pair")["token"] as? String
        precondition(token != nil)
        let status = try await request("status")
        precondition(status["blenderAvailable"] as? Bool == true)

        // Reuse the real resources but explicitly lower only test fixture targets.
        let original = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let length = original[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        var manifest = try JSONSerialization.jsonObject(with: original[12..<12 + length]) as! [String: Any]
        manifest["renderSize"] = ["width": 64, "height": 48]
        manifest["renderJob"] = ["samples": 1, "bounces": 6, "transmissiveBounces": 10]
        let json = try JSONSerialization.data(withJSONObject: manifest)
        var size = UInt32(json.count).littleEndian
        let fixture = root.appendingPathComponent("fixture.dvrender")
        FileManager.default.createFile(atPath: fixture.path, contents: nil)
        let output = try FileHandle(forWritingTo: fixture)
        try output.write(contentsOf: Data("DVRENDER".utf8))
        try withUnsafeBytes(of: &size) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: json)
        try output.write(contentsOf: original[(12 + length)...])
        try output.close()
        let total = Int64((try fixture.resourceValues(forKeys: [.fileSizeKey])).fileSize!)
        let key = UUID().uuidString
        func upload(_ key: String) async throws -> String {
            let begin = try await request("uploadBegin", ["key": key, "totalBytes": total])
            let id = begin["uploadID"] as! String
            let input = try FileHandle(forReadingFrom: fixture)
            defer { try? input.close() }
            var offset: Int64 = 0
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                let fields: [String: Any] = ["uploadID": id, "offset": offset,
                    "base64": chunk.base64EncodedString(),
                    "digest": SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined()]
                let ack = try await request("uploadChunk", fields)
                if offset == 0 {
                    let retry = try await request("uploadChunk", fields)
                    precondition((retry["offset"] as! NSNumber).int64Value == Int64(chunk.count))
                }
                offset += Int64(chunk.count)
                precondition((ack["offset"] as! NSNumber).int64Value == offset)
                precondition(model.jobs.isEmpty || model.jobs.count == 1, "No job before commit")
            }
            let accepted = try await request("uploadFinish", ["uploadID": id])
            let duplicate = try await request("uploadFinish", ["uploadID": id])
            precondition(accepted["id"] as? String == duplicate["id"] as? String)
            return accepted["id"] as! String
        }
        let first = try await upload(key)
        precondition(model.jobs.count == 1)
        let second = try await upload(key)
        precondition(first == second && model.jobs.count == 1, "HTTP digest/idempotency must prevent duplicate jobs")
        let deadline = ContinuousClock.now + .seconds(90)
        var finished: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            finished = try await request("job", ["jobID": first])
            if ["finished", "failed", "cancelled"].contains(finished["state"] as? String ?? "") { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        precondition(finished["state"] as? String == "finished", "\(finished)")
        precondition(model.jobs[0].lastRunSettings?.samples == 1)
        let png = model.jobs[0].outputURL
        let pngSize = try png.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        precondition(pngSize > 0)
        _ = try await request("disconnect")
        print("PASS: chunked Native Messaging router -> authenticated HTTP -> real Cycles queue, status, duplicate ACK/commit/full retry, PNG")
    }
}
