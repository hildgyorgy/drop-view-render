import Foundation
import CryptoKit
import Darwin

struct SafariBridgeError: Error {
    let code: String
    let status: Int
    init(_ code: String, _ status: Int = 400) { self.code = code; self.status = status }
}

/// Durable, bounded staging in the extension's private cache. No App Group is
/// needed: the existing authenticated HTTP bridge streams the committed file.
final class SafariUploadStore {
    static let chunkBytes = 64 * 1024
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    let root: URL
    private struct Record: Codable {
        var id: String
        var owner: String
        var key: String
        var total: Int64
        var received: Int64 = 0
        var touched = Date()
        var lease: String?
        var leaseUntil: Date?
        var jobID: String?
    }
    struct Commit {
        let url: URL
        let lease: String
        let key: String
    }

    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DropViewRenderSafariUploads", isDirectory: true)) { self.root = root }

    static func owner(origin: String, token: String) -> String {
        SHA256.hash(data: Data((origin + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SafariBridgeError("upload_storage_failed", 500) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SafariBridgeError("upload_busy", 429) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func metadata(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw SafariBridgeError("invalid_upload_id") }
        return root.appendingPathComponent(id + ".json")
    }
    private func payload(_ id: String) -> URL { root.appendingPathComponent(id + ".partial") }
    private func read(_ id: String, owner: String) throws -> Record {
        let url = try metadata(id)
        guard let data = try? Data(contentsOf: url), data.count < 4096,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.owner == owner else {
            throw SafariBridgeError("upload_not_found", 404)
        }
        return record
    }
    private func save(_ record: Record) throws {
        try JSONEncoder().encode(record).write(to: metadata(record.id), options: .atomic)
    }
    private func remove(_ record: Record) {
        try? FileManager.default.removeItem(at: payload(record.id))
        try? FileManager.default.removeItem(at: metadata(record.id))
    }
    private func records() throws -> [Record] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0), data.count < 4096 else { return nil }
                return try? JSONDecoder().decode(Record.self, from: data)
            }
    }

    func begin(owner: String, key: String, total: Int64) throws -> [String: Any] {
        try locked {
            guard UUID(uuidString: key) != nil, (24...Self.maximumBytes).contains(total) else {
                throw SafariBridgeError("invalid_package_size")
            }
            for record in try records() where Date().timeIntervalSince(record.touched) > (record.jobID == nil ? 900 : 86400) {
                remove(record)
            }
            let current = try records()
            if current.contains(where: { $0.owner == owner && $0.key == key && $0.total != total }) {
                throw SafariBridgeError("idempotency_conflict", 409)
            }
            if var previous = current.first(where: { $0.owner == owner && $0.key == key && $0.jobID == nil }) {
                guard previous.total == total else { throw SafariBridgeError("idempotency_conflict", 409) }
                previous.touched = Date()
                try save(previous)
                // Recheck the acknowledged prefix on retries; a reused key with
                // different bytes must never silently reuse/mix an earlier file.
                return ["uploadID": previous.id, "offset": 0, "chunkBytes": Self.chunkBytes]
            }
            let active = current.filter { $0.jobID == nil }
            guard active.count < 4, current.count < 128 else { throw SafariBridgeError("upload_busy", 429) }
            guard active.reduce(Int64(0), { $0 + $1.total }) + total <= 4 * 1024 * 1024 * 1024 else {
                throw SafariBridgeError("upload_storage_full", 413)
            }
            let record = Record(id: UUID().uuidString, owner: owner, key: key, total: total)
            guard FileManager.default.createFile(atPath: payload(record.id).path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw SafariBridgeError("upload_storage_failed", 500)
            }
            do { try save(record) } catch { remove(record); throw error }
            return ["uploadID": record.id, "offset": 0, "chunkBytes": Self.chunkBytes]
        }
    }

    func append(id: String, owner: String, offset: Int64, base64: String, digest: String) throws -> [String: Any] {
        guard base64.utf8.count <= (Self.chunkBytes + 2) / 3 * 4,
              let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= Self.chunkBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw SafariBridgeError("invalid_chunk")
        }
        return try locked {
            var record = try read(id, owner: owner)
            guard record.jobID == nil, record.leaseUntil ?? .distantPast < Date() else {
                throw SafariBridgeError("upload_committing", 409)
            }
            let handle = try FileHandle(forUpdating: payload(id))
            defer { try? handle.close() }
            if offset >= 0, offset < record.received, offset + Int64(bytes.count) <= record.received {
                // Lost ACK/retry: acknowledge only identical stored bytes.
                try handle.seek(toOffset: UInt64(offset))
                guard try handle.read(upToCount: bytes.count) == bytes else { throw SafariBridgeError("chunk_conflict", 409) }
            } else {
                guard offset == record.received, offset >= 0, Int64(bytes.count) <= record.total - offset else {
                    throw SafariBridgeError("invalid_offset", 409)
                }
                // A crash between write and metadata update is safe to retry.
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: bytes)
                try handle.truncate(atOffset: UInt64(offset + Int64(bytes.count)))
                record.received += Int64(bytes.count)
            }
            record.touched = Date()
            try save(record)
            return ["uploadID": id, "offset": offset + Int64(bytes.count)]
        }
    }

    func prepareCommit(id: String, owner: String) throws -> Commit {
        try locked {
            var record = try read(id, owner: owner)
            guard record.jobID == nil else { throw SafariBridgeError("upload_already_submitted", 409) }
            guard record.leaseUntil ?? .distantPast < Date() else { throw SafariBridgeError("upload_committing", 409) }
            guard record.received == record.total,
                  (try payload(id).resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(record.total) else {
                throw SafariBridgeError("incomplete_upload", 409)
            }
            let handle = try FileHandle(forReadingFrom: payload(id))
            defer { try? handle.close() }
            guard try handle.read(upToCount: 8) == Data("DVRENDER".utf8) else { throw SafariBridgeError("invalid_package") }
            let lease = UUID().uuidString
            record.lease = lease
            record.leaseUntil = Date().addingTimeInterval(600)
            record.touched = Date()
            try save(record)
            return Commit(url: payload(id), lease: lease, key: record.key)
        }
    }

    func acceptedJob(id: String, owner: String) throws -> String? { try locked { try read(id, owner: owner).jobID } }

    func complete(id: String, owner: String, lease: String, jobID: String?) throws {
        try locked {
            var record = try read(id, owner: owner)
            guard record.lease == lease else { throw SafariBridgeError("upload_busy", 409) }
            record.lease = nil
            record.leaseUntil = nil
            record.jobID = jobID
            record.touched = Date()
            try save(record)
            if jobID != nil { try? FileManager.default.removeItem(at: payload(id)) }
        }
    }

    func abort(id: String, owner: String) throws {
        try locked {
            let record = try read(id, owner: owner)
            guard record.jobID == nil, record.leaseUntil ?? .distantPast < Date() else {
                throw SafariBridgeError("upload_committing", 409)
            }
            remove(record)
        }
    }
}
