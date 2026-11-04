import Foundation
import CryptoKit

@main
struct SafariUploadStoreSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dvr-store-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SafariUploadStore(root: root)
        let owner = SafariUploadStore.owner(origin: "https://example.com", token: "a")
        let key = UUID().uuidString
        let chunk = Data("DVRENDER".utf8) + Data(repeating: 3, count: 65528)
        let hash = SHA256.hash(data: chunk).map { String(format: "%02x", $0) }.joined()
        let begin = try store.begin(owner: owner, key: key, total: 131072)
        let id = begin["uploadID"] as! String
        func expect(_ code: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected \(code)") }
            catch { precondition((error as? SafariBridgeError)?.code == code, "\(error)") }
        }
        expect("incomplete_upload") { _ = try store.prepareCommit(id: id, owner: owner) }
        expect("upload_not_found") { _ = try store.append(id: id, owner: "other", offset: 0, base64: chunk.base64EncodedString(), digest: hash) }
        expect("invalid_chunk") { _ = try store.append(id: id, owner: owner, offset: 0, base64: chunk.base64EncodedString(), digest: "wrong") }
        expect("invalid_offset") { _ = try store.append(id: id, owner: owner, offset: 1, base64: chunk.base64EncodedString(), digest: hash) }
        _ = try store.append(id: id, owner: owner, offset: 0, base64: chunk.base64EncodedString(), digest: hash)
        let resume = try store.begin(owner: owner, key: key, total: 131072)
        precondition(resume["uploadID"] as? String == id && resume["offset"] as? Int == 0)
        _ = try store.append(id: id, owner: owner, offset: 0, base64: chunk.base64EncodedString(), digest: hash)
        let changed = Data(repeating: 4, count: 65536)
        let changedHash = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        expect("chunk_conflict") { _ = try store.append(id: id, owner: owner, offset: 0, base64: changed.base64EncodedString(), digest: changedHash) }
        _ = try store.append(id: id, owner: owner, offset: 65536, base64: chunk.base64EncodedString(), digest: hash)
        let commit = try store.prepareCommit(id: id, owner: owner)
        expect("upload_committing") { try store.abort(id: id, owner: owner) }
        expect("upload_committing") { _ = try store.prepareCommit(id: id, owner: owner) }
        try store.complete(id: id, owner: owner, lease: commit.lease, jobID: nil)
        let second = try store.prepareCommit(id: id, owner: owner)
        try store.complete(id: id, owner: owner, lease: second.lease, jobID: UUID().uuidString)
        precondition(!FileManager.default.fileExists(atPath: commit.url.path))
        let acceptedJob = try store.acceptedJob(id: id, owner: owner)
        precondition(acceptedJob != nil)
        let next = try store.begin(owner: owner, key: key, total: 131072)
        precondition(next["uploadID"] as? String != id, "A full retry rechecks all bytes via the HTTP digest")
        try store.abort(id: next["uploadID"] as! String, owner: owner)
        expect("invalid_package_size") { _ = try store.begin(owner: owner, key: UUID().uuidString, total: SafariUploadStore.maximumBytes + 1) }
        expect("invalid_upload_id") { try store.abort(id: "../escape", owner: owner) }
        if CommandLine.arguments.contains("--stress") {
            let count = 4096 // 256 MiB streamed with one reusable 64 KiB source.
            let big = try store.begin(owner: owner, key: UUID().uuidString, total: Int64(count * chunk.count))
            let bigID = big["uploadID"] as! String
            let encoded = chunk.base64EncodedString()
            for index in 0..<count {
                _ = try autoreleasepool {
                    try store.append(id: bigID, owner: owner, offset: Int64(index * chunk.count), base64: encoded, digest: hash)
                }
            }
            let staged = try store.prepareCommit(id: bigID, owner: owner)
            let fileSize = try staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            precondition(fileSize == count * chunk.count)
            try store.complete(id: bigID, owner: owner, lease: staged.lease, jobID: UUID().uuidString)
            precondition(!FileManager.default.fileExists(atPath: staged.url.path))
            print("PASS: 256 MiB staging stress in 4096 acknowledged 64 KiB chunks; payload cleaned after acceptance")
        }
        print("PASS: bounded upload store, UTF-8/base64 limits, checksum, order, duplicate/prefix integrity, ownership, commit lease, cleanup")
    }
}
