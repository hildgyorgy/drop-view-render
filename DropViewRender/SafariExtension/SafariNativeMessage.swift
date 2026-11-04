import Foundation
import CoreFoundation

enum SafariNativeMessage {
    static let maximumMessageBytes = 100_000

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) <= 9_007_199_254_740_991 else { return nil }
        return number.int64Value
    }

    static func envelope(_ value: Any?) throws -> [String: Any] {
        guard let message = value as? [String: Any], JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message),
              encoded.count <= maximumMessageBytes,
              message["operation"] as? String != "ping" || encoded.count <= 8192 else {
            throw SafariBridgeError("invalid_message")
        }
        guard let id = message["id"] as? String, UUID(uuidString: id) != nil else { throw SafariBridgeError("invalid_id") }
        guard integer(message["protocolVersion"]) == 1 else { throw SafariBridgeError("unsupported_protocol") }
        guard let page = message["pageURL"] as? String, allowedPage(page) else { throw SafariBridgeError("origin_not_allowed", 403) }
        return message
    }

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
        let message: [String: Any]
        do { message = try envelope(value) }
        catch { return failure((error as? SafariBridgeError)?.code ?? "invalid_message") }
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
