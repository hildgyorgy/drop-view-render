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

    struct Environment: Decodable {
        let name: String
        let resource: Int
    }

    let version: Int
    let fileName: String
    let renderSize: RenderSize?
    let renderJob: RenderJob?
    let environment: Environment?
    let lengths: [UInt64]
}

enum RenderInputValidator {
    static let maximumPackageBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumManifestBytes: UInt32 = 4 * 1_024 * 1_024
    static let maximumHDRBytes: UInt64 = 256 * 1_024 * 1_024
    static let maximumHDRPixels: UInt64 = 32_000_000

    static func validateGLB(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 12 else {
            throw InputValidationError.invalidGLB
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("glTF".utf8) else {
            throw InputValidationError.invalidGLB
        }
        guard littleEndianUInt32(in: header, offset: 4) == 2 else {
            throw InputValidationError.invalidGLB
        }
        let declaredLength = littleEndianUInt32(in: header, offset: 8)
        guard UInt64(declaredLength) == UInt64(fileSize) else {
            throw InputValidationError.invalidGLBLength
        }
    }

    static func readPackage(at url: URL) throws -> DVRenderManifest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw InputValidationError.notAFile
        }
        guard fileSize >= 24, UInt64(fileSize) <= maximumPackageBytes else {
            throw InputValidationError.invalidPackageSize
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              header.prefix(8) == Data("DVRENDER".utf8) else {
            throw InputValidationError.invalidMagic
        }

        let manifestLength = littleEndianUInt32(in: header, offset: 8)
        guard manifestLength > 0, manifestLength <= maximumManifestBytes else {
            throw InputValidationError.invalidManifestSize
        }

        let data = try handle.read(upToCount: Int(manifestLength)) ?? Data()
        guard data.count == Int(manifestLength) else {
            throw InputValidationError.truncatedManifest
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["workbench"] == nil,
              raw["resolvedModel"] == nil,
              raw["viewSession"] is [String: Any],
              raw["producer"] is [String: Any] else {
            throw InputValidationError.unsupportedManifest
        }

        let manifest = try JSONDecoder().decode(DVRenderManifest.self, from: data)
        try validate(manifest)

        var expectedSize = UInt64(12) + UInt64(manifestLength)
        for length in manifest.lengths {
            let (sum, overflow) = expectedSize.addingReportingOverflow(length)
            guard !overflow else { throw InputValidationError.lengthMismatch }
            expectedSize = sum
        }
        guard expectedSize == UInt64(fileSize) else {
            throw InputValidationError.lengthMismatch
        }

        let resourceStart = UInt64(12) + UInt64(manifestLength)
        try handle.seek(toOffset: resourceStart)
        let glbHeader = try handle.read(upToCount: 12) ?? Data()
        guard glbHeader.count == 12,
              glbHeader.prefix(4) == Data("glTF".utf8),
              littleEndianUInt32(in: glbHeader, offset: 4) == 2,
              UInt64(littleEndianUInt32(in: glbHeader, offset: 8)) == manifest.lengths[0] else {
            throw InputValidationError.invalidPackagedGLB
        }

        if let environment = manifest.environment {
            let hdriOffset = resourceStart + manifest.lengths[0]
            try handle.seek(toOffset: hdriOffset)
            let headerLength = Int(min(manifest.lengths[environment.resource], 32_768))
            let hdriHeader = try handle.read(upToCount: headerLength) ?? Data()
            try validateHDRHeader(hdriHeader)
        }
        return manifest
    }

    private static func validate(_ manifest: DVRenderManifest) throws {
        guard manifest.version == 1,
              (1...2).contains(manifest.lengths.count),
              manifest.lengths[0] >= 12,
              isSafeFileName(manifest.fileName),
              manifest.fileName.lowercased().hasSuffix(".glb") else {
            throw InputValidationError.unsupportedManifest
        }
        if let size = manifest.renderSize {
            guard (1...16_384).contains(size.width),
                  (1...16_384).contains(size.height) else {
                throw InputValidationError.invalidRenderSettings
            }
        }
        if let job = manifest.renderJob {
            guard (1...100_000).contains(job.samples),
                  (1...64).contains(job.bounces),
                  (1...64).contains(job.transmissiveBounces) else {
                throw InputValidationError.invalidRenderSettings
            }
        }
        if let environment = manifest.environment {
            guard manifest.lengths.count == 2,
                  environment.resource == 1,
                  isSafeFileName(environment.name),
                  environment.name.lowercased().hasSuffix(".hdr"),
                  manifest.lengths[1] > 0,
                  manifest.lengths[1] <= maximumHDRBytes else {
                throw InputValidationError.invalidEnvironment
            }
        } else if manifest.lengths.count != 1 {
            throw InputValidationError.invalidEnvironment
        }
    }

    private static func validateHDRHeader(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#?RADIANCE") || text.hasPrefix("#?RGBE") else {
            throw InputValidationError.invalidEnvironment
        }
        let expression = try NSRegularExpression(pattern: #"[+-]Y\s+(\d+)\s+[+-]X\s+(\d+)"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let heightRange = Range(match.range(at: 1), in: text),
              let widthRange = Range(match.range(at: 2), in: text),
              let height = UInt64(text[heightRange]),
              let width = UInt64(text[widthRange]),
              height > 0, width > 0,
              height <= maximumHDRPixels / width else {
            throw InputValidationError.invalidEnvironment
        }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= 255
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.value < 32 })
    }

    private static func littleEndianUInt32(in data: Data, offset: Int) -> UInt32 {
        data.dropFirst(offset).withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
        }
    }
}

enum InputValidationError: LocalizedError {
    case notAFile
    case invalidGLB
    case invalidGLBLength
    case invalidPackageSize
    case invalidMagic
    case invalidManifestSize
    case truncatedManifest
    case unsupportedManifest
    case lengthMismatch
    case invalidPackagedGLB
    case invalidEnvironment
    case invalidRenderSettings

    var errorDescription: String? {
        switch self {
        case .notAFile: "The selected input is not a regular file."
        case .invalidGLB: "The selected file is not a valid GLB 2.0 file."
        case .invalidGLBLength: "The GLB length does not match its header."
        case .invalidPackageSize: "The .dvrender package size is invalid."
        case .invalidMagic: "The file is not a Drop & View render package."
        case .invalidManifestSize: "The package manifest size is invalid."
        case .truncatedManifest: "The package manifest is truncated."
        case .unsupportedManifest: "The package manifest is unsupported or incomplete."
        case .lengthMismatch: "The package length does not match its manifest."
        case .invalidPackagedGLB: "The packaged model is not a complete GLB resource."
        case .invalidEnvironment: "The packaged HDRI resource is invalid."
        case .invalidRenderSettings: "The packaged render settings are outside supported limits."
        }
    }
}
