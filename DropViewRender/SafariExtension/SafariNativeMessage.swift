import Foundation
import CoreFoundation

// Phase 1 is deliberately a bounded diagnostic endpoint. No files or queue access.
enum SafariNativeMessage {
    static let maximumMessageBytes = 8192

    static func allowedPage(_ value: String) -> Bool {
        guard let url = URL(string: value), url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        if url.scheme == "https", host == "hildgyorgy.github.io",
           url.port == nil || url.port == 443 {
            return url.path == "/drop-3d-view" || url.path.hasPrefix("/drop-3d-view/")
        }
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
    }

    static func reply(to value: Any?) -> [String: Any] {
        var id = ""
        func failure(_ code: String) -> [String: Any] {
            ["protocolVersion": 1, "id": id, "ok": false, "error": code]
        }
        guard let message = value as? [String: Any],
              JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message),
              encoded.count <= maximumMessageBytes else { return failure("invalid_message") }
        guard let requestID = message["id"] as? String,
              UUID(uuidString: requestID) != nil else { return failure("invalid_id") }
        id = requestID
        guard let version = message["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else {
            return failure("unsupported_protocol")
        }
        // URL is supplied by the background script from Safari's sender metadata.
        guard let page = message["pageURL"] as? String, allowedPage(page) else {
            return failure("origin_not_allowed")
        }
        guard message["operation"] as? String == "ping" else { return failure("unsupported_operation") }
        guard let text = message["text"] as? String, text.utf8.count <= 1024 else {
            return failure("invalid_text")
        }
        return [
            "protocolVersion": 1, "id": id, "ok": true, "operation": "pong",
            "app": "Drop & View Render", "transport": "safari-native-messaging",
            "responder": "SafariWebExtensionHandler", "capabilities": ["ping"],
            "text": text, "nativeProcessID": ProcessInfo.processInfo.processIdentifier,
            "nativeBundleIdentifier": Bundle.main.bundleIdentifier ?? "test-harness"
        ]
    }
}
