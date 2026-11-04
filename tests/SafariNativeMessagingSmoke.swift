// Compile with all SafariExtension/*.swift sources; see docs/SAFARI_NATIVE_MESSAGING.md.
import Foundation
import SafariServices

final class ProbeContext: NSExtensionContext {
    var incoming: [Any] = []
    var outgoing: [Any] = []
    override var inputItems: [Any] { incoming }
    override func completeRequest(returningItems items: [Any]?, completionHandler: ((Bool) -> Void)? = nil) {
        outgoing = items ?? []
        completionHandler?(false)
    }
}

@main
struct SafariNativeMessagingSmoke {
    static func exchange(_ message: Any?) -> [String: Any] {
        let item = NSExtensionItem()
        if let message { item.userInfo = [SFExtensionMessageKey: message] }
        let context = ProbeContext()
        context.incoming = [item]
        SafariWebExtensionHandler().beginRequest(with: context)
        precondition(context.outgoing.count == 1)
        return (context.outgoing[0] as! NSExtensionItem).userInfo![SFExtensionMessageKey] as! [String: Any]
    }

    static func main() throws {
        // --stdio is a test-only adapter used by the JS integration test.
        if CommandLine.arguments.contains("--stdio") {
            let bytes = try FileHandle.standardInput.read(upToCount: 8193) ?? Data()
            let input = try JSONSerialization.jsonObject(with: bytes)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: exchange(input)))
            return
        }
        let id = UUID().uuidString
        let valid: [String: Any] = ["protocolVersion": 1, "id": id, "operation": "ping",
                                    "text": "Árvíztűrő 🪟", "pageURL": "https://hildgyorgy.github.io/drop-3d-view/"]
        let pong = exchange(valid)
        precondition(pong["ok"] as? Bool == true && pong["id"] as? String == id)
        precondition(pong["text"] as? String == valid["text"] as? String)
        precondition(pong["responder"] as? String == "SafariWebExtensionHandler")
        for page in ["http://localhost:4173/", "http://127.0.0.1:8080/"] {
            precondition(exchange(valid.merging(["pageURL": page]) { _, new in new })["ok"] as? Bool == true)
        }
        let invalid: [(String, Any, String)] = [
            ("pageURL", "https://evil.example/", "origin_not_allowed"),
            ("pageURL", "https://hildgyorgy.github.io/another-project/", "origin_not_allowed"),
            ("pageURL", "http://localhost.evil.example/", "origin_not_allowed"),
            ("pageURL", "https://hildgyorgy.github.io:444/drop-3d-view/", "origin_not_allowed"),
            ("operation", "render", "unsupported_operation"),
            ("protocolVersion", true, "unsupported_protocol"),
            ("protocolVersion", 2, "unsupported_protocol"),
            ("id", "no-id", "invalid_id"),
            ("text", String(repeating: "é", count: 513), "invalid_text")
        ]
        for (key, value, error) in invalid {
            let response = exchange(valid.merging([key: value]) { _, new in new })
            precondition(response["ok"] as? Bool == false && response["error"] as? String == error)
        }
        precondition(exchange(nil)["error"] as? String == "invalid_message")
        precondition(exchange(valid.merging(["extra": String(repeating: "x", count: 9000)]) { _, new in new })["error"] as? String == "invalid_message")
        print("PASS: NSExtensionItem -> production Swift handler -> NSExtensionItem pong, validation and limits")
    }
}
