import AppKit
import CryptoKit
import Network
import SwiftUI

/// Single-request HTTP/1.1 bridge with bounded, streamed scene uploads.
@MainActor
final class BrowserBridge: ObservableObject {
    static let port: UInt16 = 43127
    @Published private(set) var status = "Starting browser bridge…"
    @Published private(set) var connectedOrigins: [String] = []
    var rendererStatus: () -> [String: Any] = { [:] }
    var submitJob: ((URL, DVRenderManifest, URL, Bool, Bool) throws -> UUID)?
    var jobStatus: ((UUID) -> [String: Any]?)?
    var cancelJob: ((UUID) -> Bool)?
    var revealJob: ((UUID) -> Bool)?
    var outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Drop & View Render", isDirectory: true)
    private let uploadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("drop-view-browser-\(UUID().uuidString)", isDirectory: true)
    private struct Submission {
        let origin: String
        let key: String
        let digest: String
        let jobID: UUID
        let denoise: Bool
        let adaptive: Bool
    }
    private var submissions: [Submission] = []
    private var uploadClientID: UUID?
    private var retainedBytes: UInt64 = 0
    private struct UploadSettings: Decodable {
        let version: Int
        let profile: String
        let denoise: Bool?
        let adaptive: Bool?
    }
    var approvePairing: ((String, @escaping (Bool) -> Void) -> Void)?

    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var sessions: [String: String] = [:]
    private var pairingPending = false
    private var lastPairing = Date.distantPast
    private let queue = DispatchQueue(label: "DropViewRender.browserBridge")

    private final class Client {
        let connection: NWConnection
        var bytes = Data()
        var timer: Timer?
        var upload: FileHandle?
        var uploadURL: URL?
        var remaining = 0
        var origin = ""
        var token = ""
        var key = ""
        var denoise = true
        var adaptive = true
        var digest = SHA256()
        var processing = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let server = try NWListener(using: parameters)
            listener = server
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === server else { return }
                    switch state {
                    case .ready: self.status = "Browser bridge: 127.0.0.1:\(Self.port)"
                    case .failed(let error):
                        self.stop()
                        self.status = "Browser bridge unavailable: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            server.start(queue: queue)
        } catch {
            status = "Browser bridge unavailable: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { close(id) }
        revokeSessions()
        // A listener failure must not remove a package still used by Blender.
        if rendererStatus()["rendering"] as? Bool != true {
            try? FileManager.default.removeItem(at: uploadRoot)
            submissions.removeAll()
            retainedBytes = 0
        }
        status = "Browser bridge stopped"
    }

    func revokeSessions() {
        sessions.removeAll()
        connectedOrigins = []
        if let id = uploadClientID { close(id) }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, clients.count < 16 else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        client.timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timer?.invalidate()
        client.connection.cancel()
        try? client.upload?.close()
        if let url = client.uploadURL { try? FileManager.default.removeItem(at: url) }
        if uploadClientID == id { uploadClientID = nil }
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.clients[id] else { return }
                if client.processing { return }
                if client.upload != nil {
                    self.consumeUpload(id, data: data ?? Data())
                    if client.processing { return }
                } else {
                    if let data { client.bytes.append(data) }
                    if self.parse(id) { return }
                }
                if complete || error != nil { self.close(id) } else { self.receive(id) }
            }
        }
    }

    private func parse(_ id: UUID) -> Bool {
        guard let client = clients[id] else { return true }
        let data = client.bytes
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16 * 1024 { reply(id, code: 413, object: ["error": "headers_too_large"]); return true }
            return false
        }
        guard end.upperBound <= 16 * 1024,
              let header = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            reply(id, code: 400, object: ["error": "invalid_headers"]); return true
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                reply(id, code: 400, object: ["error": "invalid_headers"]); return true
            }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else {
                reply(id, code: 400, object: ["error": "duplicate_header"]); return true
            }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard request.count == 3, request[2] == "HTTP/1.1",
              headers["host"] == "127.0.0.1:\(Self.port)", headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            reply(id, code: 400, object: ["error": "invalid_request"]); return true
        }
        let origin = headers["origin"] ?? ""
        guard Self.isAllowedOrigin(origin) else {
            reply(id, code: 403, object: ["error": "origin_denied"]); return true
        }
        if request[0] == "POST", request[1] == "/v1/jobs" {
            beginUpload(id, origin: origin, headers: headers, length: length,
                        initial: Data(data[end.upperBound...]))
            return client.processing
        }
        guard length <= 1024 else { reply(id, code: 413, origin: origin, object: ["error": "request_too_large"]); return true }
        guard data.count >= end.upperBound + length else { return false }
        guard data.count == end.upperBound + length else {
            reply(id, code: 400, origin: origin, object: ["error": "unexpected_body"]); return true
        }
        route(id, method: String(request[0]), path: String(request[1]), origin: origin, headers: headers)
        return true
    }

    static func isAllowedOrigin(_ origin: String) -> Bool {
        if origin == "https://hildgyorgy.github.io" { return true }
        guard let url = URLComponents(string: origin), url.scheme == "http",
              ["localhost", "127.0.0.1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil else { return false }
        return origin == "http://\(url.host!)" + (url.port.map { ":\($0)" } ?? "")
    }

    private func route(_ id: UUID, method: String, path: String, origin: String, headers: [String: String]) {
        guard ["/v1/status", "/v1/pair", "/v1/jobs"].contains(path) || path.hasPrefix("/v1/jobs/") else {
            reply(id, code: 404, origin: origin, object: ["error": "not_found"]); return
        }
        if method == "OPTIONS" {
            let requested = headers["access-control-request-method"] ?? ""
            let fields = (headers["access-control-request-headers"] ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ["GET", "POST", "DELETE"].contains(requested),
                  fields.allSatisfy({ ["authorization", "content-type", "idempotency-key", "x-dvr-settings"].contains($0) }) else {
                reply(id, code: 403, origin: origin, object: ["error": "preflight_denied"]); return
            }
            reply(id, code: 204, origin: origin, object: [:]); return
        }
        if method == "POST", path == "/v1/pair" {
            guard !pairingPending, Date().timeIntervalSince(lastPairing) >= 5, sessions.count < 16 else {
                reply(id, code: 429, origin: origin, object: ["error": "pairing_busy"]); return
            }
            pairingPending = true
            lastPairing = Date()
            let finish: (Bool) -> Void = { [weak self] approved in
                guard let self else { return }
                self.pairingPending = false
                guard self.clients[id] != nil else { return }
                guard approved else {
                    self.reply(id, code: 403, origin: origin, object: ["error": "pairing_denied"]); return
                }
                let token = UUID().uuidString + UUID().uuidString
                self.sessions[token] = origin
                self.connectedOrigins = Array(Set(self.sessions.values)).sorted()
                self.reply(id, code: 200, origin: origin, object: ["token": token, "protocolVersion": 1])
            }
            if let approvePairing { approvePairing(origin, finish) } else {
                let alert = NSAlert()
                alert.messageText = "Connect to Drop & View?"
                alert.informativeText = "Allow \(origin) to connect to this app until it quits? This allows scene uploads, rendering, cancellation and showing completed images in Finder."
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    alert.beginSheetModal(for: window) { response in finish(response == .alertFirstButtonReturn) }
                } else { finish(false) }
            }
            return
        }
        let authorization = headers["authorization"] ?? ""
        let token = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
        guard sessions[token] == origin else {
            reply(id, code: 401, origin: origin, object: ["error": "pairing_required"]); return
        }
        if method == "DELETE", path == "/v1/pair" {
            sessions.removeValue(forKey: token)
            connectedOrigins = Array(Set(sessions.values)).sorted()
            reply(id, code: 200, origin: origin, object: ["disconnected": true]); return
        }
        if path.hasPrefix("/v1/jobs/") {
            routeJob(id, method: method, path: path, origin: origin)
            return
        }
        guard method == "GET", path == "/v1/status" else {
            reply(id, code: 405, origin: origin, object: ["error": "method_not_allowed"]); return
        }
        var result = rendererStatus()
        result["app"] = "Drop & View Render"
        result["protocolVersion"] = 1
        result["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        result["capabilities"] = ["status", "jobs", "cancel", "reveal", "quality-controls"]
        reply(id, code: 200, origin: origin, object: result)
    }

    private func beginUpload(_ id: UUID, origin: String, headers: [String: String], length: Int, initial: Data) {
        let token = String((headers["authorization"] ?? "").dropFirst(7))
        guard headers["authorization"]?.hasPrefix("Bearer ") == true, sessions[token] == origin else {
            reply(id, code: 401, origin: origin, object: ["error": "pairing_required"]); return
        }
        guard length >= 24, UInt64(length) <= RenderInputValidator.maximumPackageBytes else {
            reply(id, code: 413, origin: origin, object: ["error": "invalid_package_size"]); return
        }
        guard headers["content-type"] == "application/octet-stream",
              let key = headers["idempotency-key"], UUID(uuidString: key) != nil,
              let settings = headers["x-dvr-settings"], settings.utf8.count <= 1024,
              let values = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any],
              Set(values.keys).isSubset(of: ["version", "profile", "denoise", "adaptive"]),
              let decoded = try? JSONDecoder().decode(UploadSettings.self, from: Data(settings.utf8)),
              decoded.version == 1, decoded.profile == "recommended" else {
            reply(id, code: 400, origin: origin, object: ["error": "invalid_submission"]); return
        }
        guard uploadClientID == nil else {
            reply(id, code: 429, origin: origin, object: ["error": "upload_busy"]); return
        }
        // Retries may recover an accepted job while it is rendering.
        let existing = submissions.contains { $0.origin == origin && $0.key == key }
        guard existing || submissions.count < 64 else {
            reply(id, code: 429, origin: origin, object: ["error": "session_job_limit"]); return
        }
        guard existing || retainedBytes + UInt64(length) <= 8 * 1024 * 1024 * 1024 else {
            reply(id, code: 413, origin: origin, object: ["error": "session_storage_full"]); return
        }
        guard existing || rendererStatus()["blenderAvailable"] as? Bool == true else {
            reply(id, code: 503, origin: origin, object: ["error": "blender_unavailable"]); return
        }
        guard let client = clients[id] else { return }
        do {
            try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let url = uploadRoot.appendingPathComponent("\(UUID().uuidString).partial")
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            client.uploadURL = url
            client.upload = try FileHandle(forWritingTo: url)
            client.remaining = length
            client.origin = origin
            client.token = token
            client.key = key
            client.denoise = decoded.denoise ?? true
            client.adaptive = decoded.adaptive ?? true
            client.bytes.removeAll()
            uploadClientID = id
            client.timer?.invalidate()
            client.timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.close(id) }
            }
            consumeUpload(id, data: initial)
        } catch {
            reply(id, code: 500, origin: origin, object: ["error": "upload_storage_failed"])
        }
    }

    private func consumeUpload(_ id: UUID, data: Data) {
        guard let client = clients[id], let handle = client.upload else { return }
        guard data.count <= client.remaining else {
            reply(id, code: 400, origin: client.origin, object: ["error": "unexpected_body"]); return
        }
        do {
            try handle.write(contentsOf: data)
            client.digest.update(data: data)
            client.remaining -= data.count
            guard client.remaining == 0 else { return }
            try handle.close()
            client.upload = nil
            guard sessions[client.token] == client.origin else {
                reply(id, code: 401, origin: client.origin, object: ["error": "pairing_required"]); return
            }
            let digest = client.digest.finalize().map { String(format: "%02x", $0) }.joined()
            if let previous = submissions.first(where: { $0.origin == client.origin && $0.key == client.key }) {
                guard previous.digest == digest, previous.denoise == client.denoise,
                      previous.adaptive == client.adaptive else {
                    reply(id, code: 409, origin: client.origin, object: ["error": "idempotency_conflict"]); return
                }
                reply(id, code: 202, origin: client.origin, object: ["id": previous.jobID.uuidString]); return
            }
            guard let partial = client.uploadURL, let submitJob else {
                reply(id, code: 503, origin: client.origin, object: ["error": "renderer_unavailable"]); return
            }
            let manifest: DVRenderManifest
            do { manifest = try RenderInputValidator.readPackage(at: partial) }
            catch {
                reply(id, code: 400, origin: client.origin, object: ["error": "invalid_package", "message": error.localizedDescription]); return
            }
            let package = partial.deletingPathExtension().appendingPathExtension("dvrender")
            try FileManager.default.moveItem(at: partial, to: package)
            client.uploadURL = package
            let jobID = try submitJob(package, manifest, outputDirectory, client.denoise, client.adaptive)
            submissions.append(Submission(origin: client.origin, key: client.key, digest: digest, jobID: jobID,
                                          denoise: client.denoise, adaptive: client.adaptive))
            retainedBytes += UInt64((try? package.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            client.uploadURL = nil // retained for native rerenders until the app quits
            reply(id, code: 202, origin: client.origin, object: ["id": jobID.uuidString])
        } catch {
            reply(id, code: 500, origin: client.origin, object: ["error": "submission_failed"])
        }
    }

    private func routeJob(_ id: UUID, method: String, path: String, origin: String) {
        let parts = path.split(separator: "/")
        guard (3...4).contains(parts.count), let jobID = UUID(uuidString: String(parts[2])),
              submissions.contains(where: { $0.jobID == jobID && $0.origin == origin }) else {
            reply(id, code: 404, origin: origin, object: ["error": "job_not_found"]); return
        }
        guard let status = jobStatus?(jobID) else {
            reply(id, code: 410, origin: origin, object: ["error": "job_removed"]); return
        }
        if method == "GET", parts.count == 3 {
            reply(id, code: 200, origin: origin, object: status); return
        }
        if method == "POST", parts.count == 4, parts[3] == "cancel" {
            let terminal = ["finished", "cancelled", "failed"].contains(status["state"] as? String ?? "")
            if terminal || cancelJob?(jobID) == true {
                reply(id, code: 200, origin: origin, object: ["cancellationRequested": !terminal]); return
            }
        }
        if method == "POST", parts.count == 4, parts[3] == "reveal", revealJob?(jobID) == true {
            reply(id, code: 200, origin: origin, object: ["revealed": true]); return
        }
        reply(id, code: 409, origin: origin, object: ["error": "job_action_unavailable"])
    }

    private func reply(_ id: UUID, code: Int, origin: String? = nil, object: [String: Any]) {
        guard let client = clients[id] else { return }
        client.processing = true
        let body = code == 204 ? Data() : (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 413: "Content Too Large", 429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if let origin {
            header += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key, X-DVR-Settings\r\n"
        }
        client.connection.send(content: Data((header + "\r\n").utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
}
