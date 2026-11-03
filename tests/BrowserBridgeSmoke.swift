import Foundation

@main
struct BrowserBridgeSmoke {
    @MainActor
    static func main() async throws {
        let bridge = BrowserBridge()
        let origin = "https://hildgyorgy.github.io"
        var approvals = 0
        bridge.approvePairing = { requested, finish in
            precondition(requested == origin)
            approvals += 1
            finish(true)
        }
        bridge.rendererStatus = { ["blenderAvailable": true, "rendering": false] }
        bridge.start()
        defer { bridge.stop() }
        try await Task.sleep(for: .milliseconds(300))
        precondition(bridge.status.hasPrefix("Browser bridge: 127.0.0.1:"), bridge.status)

        func request(_ path: String, method: String = "GET", origin: String? = origin,
                     token: String? = nil, headers: [String: String] = [:]) async throws -> (Int, [String: Any], HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:43127/v1/\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 5
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], http)
        }

        let missing = try await request("status")
        precondition(missing.0 == 401)
        let denied = try await request("pair", method: "POST", origin: "https://evil.example")
        precondition(denied.0 == 403 && approvals == 0)
        precondition(denied.2.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
        let noOrigin = try await request("status", origin: nil)
        precondition(noOrigin.0 == 403)
        let preflight = try await request("status", method: "OPTIONS", headers: [
            "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization",
            "Access-Control-Request-Private-Network": "true"])
        precondition(preflight.0 == 204)
        precondition(preflight.2.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == origin)
        let pair = try await request("pair", method: "POST")
        precondition(pair.0 == 200 && approvals == 1)
        let token = pair.1["token"] as! String
        precondition(token.count == 72 && bridge.connectedOrigins == [origin])
        let status = try await request("status", token: token)
        precondition(status.0 == 200 && status.1["blenderAvailable"] as? Bool == true)
        precondition(status.1["protocolVersion"] as? Int == 1)
        let wrong = try await request("status", token: "wrong")
        precondition(wrong.0 == 401)
        let otherOrigin = try await request("status", origin: "http://localhost:8000", token: token)
        precondition(otherOrigin.0 == 401)
        let upload = try await request("jobs", method: "POST", token: token)
        precondition(upload.0 == 413)
        let disconnect = try await request("pair", method: "DELETE", token: token)
        precondition(disconnect.0 == 200 && bridge.connectedOrigins.isEmpty)
        let expired = try await request("status", token: token)
        precondition(expired.0 == 401)
        for invalid in ["null", "https://hildgyorgy.github.io.evil.example", "http://localhost:8000/path", "http://localhost@evil.example", "https://localhost:8000", "http://127.0.0.2:8000"] {
            precondition(!BrowserBridge.isAllowedOrigin(invalid), invalid)
        }
        print("Browser bridge HTTP smoke passed (pairing, CORS, origin-bound auth, status, disconnect).")
    }
}
