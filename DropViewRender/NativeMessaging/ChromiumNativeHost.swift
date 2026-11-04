import Foundation
import Darwin

/// Chromium length-prefixed stdio transport. stdout is exclusively protocol.
@main
struct ChromiumNativeHost {
    static func readExactly(_ count: Int, input: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let next = try input.read(upToCount: count - data.count), !next.isEmpty else {
                if data.isEmpty { return nil }
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(next)
        }
        return data
    }

    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let manifest = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/ChromiumExtension/manifest.json")
            let allowed = "chrome-extension://" + (try BrowserExtensionIdentity.identifier(manifest: manifest)) + "/"
            guard CommandLine.arguments.count >= 2, CommandLine.arguments[1] == allowed else { exit(1) }
            let router = SafariNativeRouter(transport: "chromium-native-messaging")
            let input = FileHandle.standardInput
            let output = FileHandle.standardOutput
            while let header = try readExactly(4, input: input) {
                let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                guard length > 0, length <= SafariNativeMessage.maximumMessageBytes,
                      let frame = try readExactly(Int(length), input: input) else { exit(1) }
                let message = try JSONSerialization.jsonObject(with: frame)
                let reply = await router.handle(message)
                let bytes = try JSONSerialization.data(withJSONObject: reply)
                guard bytes.count <= SafariNativeMessage.maximumMessageBytes else { exit(1) }
                var size = UInt32(bytes.count).littleEndian
                try withUnsafeBytes(of: &size) { try output.write(contentsOf: Data($0)) }
                try output.write(contentsOf: bytes)
            }
        } catch {
            // Do not echo payloads, tokens or paths into browser logs.
            try? FileHandle.standardError.write(contentsOf: Data("Drop & View Render native host: invalid input or unavailable resources.\n".utf8))
            exit(1)
        }
    }
}
