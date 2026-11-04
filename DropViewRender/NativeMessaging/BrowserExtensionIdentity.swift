import Foundation
import CryptoKit

/// Public manifest key pins the unpacked extension ID across paths and browsers.
/// This is public identity material, not a signing private key.
enum BrowserExtensionIdentity {
    static func identifier(manifest: URL) throws -> String {
        let data = try Data(contentsOf: manifest)
        guard data.count < 16384,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String, let bytes = Data(base64Encoded: key) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let alphabet = Array("abcdefghijklmnop")
        return SHA256.hash(data: bytes).prefix(16).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
            .map(String.init).joined()
    }
}
