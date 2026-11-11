import Foundation
import CoreFoundation

/// Native-side relay to the existing queue service. Safari itself never fetches
/// localhost on this transport. URL/method/header choices are fixed here.
private final class SafariNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SafariNativeRouter {
    static let operations: Set<String> = ["pair", "status", "disconnect", "job", "cancel", "reveal",
                                           "uploadBegin", "uploadChunk", "uploadFinish", "uploadAbort"]
    static let shared = SafariNativeRouter()
    let transport: String
    let store: SafariUploadStore
    private let session: URLSession
    init(store: SafariUploadStore = SafariUploadStore(), transport: String = "safari-native-messaging") {
        self.transport = transport
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: SafariNoRedirects(), delegateQueue: nil)
    }

    private func relay(_ path: String, method: String = "GET", origin: String, token: String?,
                       file: URL? = nil, key: String? = nil, denoise: Bool = true, adaptive: Bool = true) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:43127/v1/" + path)!)
        request.httpMethod = method
        request.timeoutInterval = file != nil ? 590 : (path == "pair" && method == "POST" ? 115 : 8)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        do {
            if let file, let key {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
                request.setValue(String(size), forHTTPHeaderField: "Content-Length")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
                let settings = try JSONSerialization.data(withJSONObject: ["version": 1, "profile": "recommended",
                                                                           "denoise": denoise, "adaptive": adaptive])
                request.setValue(String(decoding: settings, as: UTF8.self), forHTTPHeaderField: "X-DVR-Settings")
                result = try await session.upload(for: request, fromFile: file)
            } else { result = try await session.data(for: request) }
        } catch { throw SafariBridgeError("native_app_unavailable", 503) }
        guard let http = result.1 as? HTTPURLResponse, result.0.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] else {
            throw SafariBridgeError("invalid_native_response", 502)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SafariBridgeError(object["error"] as? String ?? "native_request_failed", http.statusCode)
        }
        return object
    }

    func handle(_ value: Any?) async -> [String: Any] {
        var id = ""
        do {
            let message = try SafariNativeMessage.envelope(value)
            id = message["id"] as! String
            let operation = message["operation"] as? String ?? ""
            if operation == "ping" {
                var reply = SafariNativeMessage.reply(to: message)
                if reply["ok"] as? Bool == true {
                    reply["transport"] = transport
                    if transport == "chromium-native-messaging" { reply["responder"] = "ChromiumNativeHost" }
                }
                return reply
            }
            let url = URLComponents(string: message["pageURL"] as! String)!
            let port = url.port == (url.scheme == "https" ? 443 : 80) ? nil : url.port
            let origin = "\(url.scheme!)://\(url.host!)" + (port.map { ":\($0)" } ?? "")
            let token = message["token"] as? String
            if operation != "pair" {
                guard let token, token.range(of: "^[A-Fa-f0-9-]{72}$", options: .regularExpression) != nil else {
                    throw SafariBridgeError("pairing_required", 401)
                }
            }
            let owner = SafariUploadStore.owner(origin: origin, token: token ?? "")
            let data: [String: Any]
            switch operation {
            case "pair": data = try await relay("pair", method: "POST", origin: origin, token: nil)
            case "status": data = try await relay("status", origin: origin, token: token)
            case "disconnect": data = try await relay("pair", method: "DELETE", origin: origin, token: token)
            case "job", "cancel", "reveal":
                guard let jobID = message["jobID"] as? String, UUID(uuidString: jobID) != nil else {
                    throw SafariBridgeError("invalid_job_id")
                }
                data = try await relay("jobs/" + jobID + (operation == "job" ? "" : "/" + operation),
                                       method: operation == "job" ? "GET" : "POST", origin: origin, token: token)
            case "uploadBegin":
                _ = try await relay("status", origin: origin, token: token)
                guard let key = message["key"] as? String,
                      let total = SafariNativeMessage.integer(message["totalBytes"]) else { throw SafariBridgeError("invalid_submission") }
                func flag(_ name: String) throws -> Bool {
                    guard let value = message[name] else { return true }
                    guard let number = value as? NSNumber,
                          CFGetTypeID(number) == CFBooleanGetTypeID() else { throw SafariBridgeError("invalid_submission") }
                    return number.boolValue
                }
                data = try store.begin(owner: owner, key: key, total: total,
                                       denoise: flag("denoise"), adaptive: flag("adaptive"))
            case "uploadChunk":
                guard let upload = message["uploadID"] as? String,
                      let offset = SafariNativeMessage.integer(message["offset"]),
                      let bytes = message["base64"] as? String, let digest = message["digest"] as? String else {
                    throw SafariBridgeError("invalid_chunk")
                }
                data = try store.append(id: upload, owner: owner, offset: offset, base64: bytes, digest: digest)
            case "uploadFinish":
                _ = try await relay("status", origin: origin, token: token)
                guard let upload = message["uploadID"] as? String else { throw SafariBridgeError("invalid_upload_id") }
                if let jobID = try store.acceptedJob(id: upload, owner: owner) { data = ["id": jobID]; break }
                let commit = try store.prepareCommit(id: upload, owner: owner)
                do {
                    data = try await relay("jobs", method: "POST", origin: origin, token: token,
                                           file: commit.url, key: commit.key, denoise: commit.denoise, adaptive: commit.adaptive)
                    guard let jobID = data["id"] as? String, UUID(uuidString: jobID) != nil else { throw SafariBridgeError("invalid_native_response", 502) }
                    try store.complete(id: upload, owner: owner, lease: commit.lease, jobID: jobID)
                } catch {
                    try? store.complete(id: upload, owner: owner, lease: commit.lease, jobID: nil)
                    throw error
                }
            case "uploadAbort":
                guard let upload = message["uploadID"] as? String else { throw SafariBridgeError("invalid_upload_id") }
                try store.abort(id: upload, owner: owner)
                data = ["aborted": true]
            default: throw SafariBridgeError("unsupported_operation")
            }
            return ["protocolVersion": 1, "id": id, "ok": true, "data": data,
                    "transport": transport]
        } catch {
            let failure = error as? SafariBridgeError ?? SafariBridgeError("native_storage_failed", 500)
            return ["protocolVersion": 1, "id": id, "ok": false, "error": failure.code, "status": failure.status]
        }
    }
}
