import Foundation

struct DVRenderManifest: Decodable {
    struct RenderSize: Decodable {
        let width: Int
        let height: Int
    }

    struct RenderJob: Decodable {
        let samples: Int
        let bounces: Int
        let transmissiveBounces: Int
    }

    let version: Int
    let renderSize: RenderSize?
    let renderJob: RenderJob?
    let lengths: [UInt64]
}

enum DVRenderManifestReader {
    static let maximumPackageBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumManifestBytes: UInt32 = 4 * 1_024 * 1_024

    static func read(from url: URL) throws -> DVRenderManifest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw ManifestError.notAFile
        }
        guard fileSize >= 24, UInt64(fileSize) <= maximumPackageBytes else {
            throw ManifestError.invalidPackageSize
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              header.prefix(8) == Data("DVRENDER".utf8) else {
            throw ManifestError.invalidMagic
        }

        let manifestLength = header.dropFirst(8).withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
        }
        guard manifestLength > 0, manifestLength <= maximumManifestBytes else {
            throw ManifestError.invalidManifestSize
        }

        let data = try handle.read(upToCount: Int(manifestLength)) ?? Data()
        guard data.count == manifestLength else {
            throw ManifestError.truncatedManifest
        }
        let manifest = try JSONDecoder().decode(DVRenderManifest.self, from: data)
        guard manifest.version == 1,
              (1...2).contains(manifest.lengths.count) else {
            throw ManifestError.unsupportedVersion
        }

        var expectedSize = UInt64(12) + UInt64(manifestLength)
        for length in manifest.lengths {
            let (sum, overflow) = expectedSize.addingReportingOverflow(length)
            guard !overflow else { throw ManifestError.lengthMismatch }
            expectedSize = sum
        }
        guard expectedSize == UInt64(fileSize) else {
            throw ManifestError.lengthMismatch
        }
        return manifest
    }
}

enum ManifestError: LocalizedError {
    case notAFile
    case invalidPackageSize
    case invalidMagic
    case invalidManifestSize
    case truncatedManifest
    case unsupportedVersion
    case lengthMismatch

    var errorDescription: String? {
        switch self {
        case .notAFile: "The selected package is not a regular file."
        case .invalidPackageSize: "The .dvrender package size is invalid."
        case .invalidMagic: "The file is not a Drop & View render package."
        case .invalidManifestSize: "The package manifest size is invalid."
        case .truncatedManifest: "The package manifest is truncated."
        case .unsupportedVersion: "The package version or resource count is unsupported."
        case .lengthMismatch: "The package length does not match its manifest."
        }
    }
}
