// Compile with DVRenderManifest.swift and RenderJob.swift, then pass a package
// exported by the web app. Checks actual image decoding and legacy fallback.
import Foundation

@main
struct ThumbnailSmoke {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try RenderInputValidator.readPackage(at: url)
        precondition(manifest.thumbnail != nil, "Export must contain a decodable thumbnail")
        let job = RenderJob(inputURL: url, manifest: manifest)
        precondition(job.thumbnail != nil)

        let bytes = try Data(contentsOf: url)
        let length = bytes.dropFirst(8).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        var metadata = try JSONSerialization.jsonObject(with: bytes.subdata(in: 12..<(12 + length))) as! [String: Any]
        let thumbnail = metadata["thumbnail"] as! [String: Any]
        let jpeg = Data(base64Encoded: thumbnail["data"] as! String)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-view-thumbnail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try jpeg.write(to: directory.appendingPathComponent("preview.jpg"))

        // Tiny valid model header is sufficient for package-reader tests.
        let glb = Data([103, 108, 84, 70, 2, 0, 0, 0, 12, 0, 0, 0])
        metadata["environment"] = nil
        metadata["lengths"] = [12]
        for variant in ["legacy", "corrupt", "wrong-size"] {
            var record = metadata
            if variant == "legacy" { record["thumbnail"] = nil }
            else {
                var invalid = thumbnail
                if variant == "corrupt" { invalid["data"] = "not-base64" }
                else { invalid["width"] = 65_535 }
                record["thumbnail"] = invalid
            }
            let json = try JSONSerialization.data(withJSONObject: record)
            var package = Data("DVRENDER".utf8)
            var size = UInt32(json.count).littleEndian
            withUnsafeBytes(of: &size) { package.append(contentsOf: $0) }
            package.append(json)
            package.append(glb)
            let file = directory.appendingPathComponent("\(variant).dvrender")
            try package.write(to: file)
            let decoded = try RenderInputValidator.readPackage(at: file)
            precondition(decoded.thumbnail == nil, variant)
        }
        print("PASS: web-exported JPEG decoded, job thumbnail, legacy/corrupt/oversized fallback")
        print("Preview: \(directory.appendingPathComponent("preview.jpg").path)")
    }
}
