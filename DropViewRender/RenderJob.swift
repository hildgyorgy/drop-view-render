import SwiftUI

struct RenderJob: Identifiable {
    let id: UUID
    let inputURL: URL
    var outputURL: URL
    var packageSummary: String?
    var overridesSourceSettings: Bool
    var width: Int
    var height: Int
    var samples: Int
    var bounces: Int
    var transmissionBounces: Int
    var showsHDRIBackground: Bool
    var state: RenderState
    var progress: Double?
    var log: String
    var errorMessage: String?
    var isInputValid: Bool
    var overwriteApproved: Bool

    init(inputURL: URL, manifest: DVRenderManifest?) {
        id = UUID()
        self.inputURL = inputURL
        outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent)-cycles.png")
        overridesSourceSettings = false
        width = manifest?.renderSize?.width ?? 1_280
        height = manifest?.renderSize?.height ?? 720
        samples = manifest?.renderJob?.samples ?? 64
        bounces = manifest?.renderJob?.bounces ?? 6
        transmissionBounces = manifest?.renderJob?.transmissiveBounces ?? 10
        showsHDRIBackground = true
        state = .queued
        progress = nil
        log = ""
        errorMessage = nil
        isInputValid = true
        overwriteApproved = false

        if let manifest {
            let size = manifest.renderSize.map { "\($0.width)×\($0.height)" } ?? "source size"
            let sampleText = manifest.renderJob.map { "\($0.samples) samples" } ?? "source quality"
            packageSummary = ".dvrender v\(manifest.version) · \(size) · \(sampleText)"
        } else {
            packageSummary = "Plain GLB · adapter defaults until overridden"
        }
    }
}

enum RenderState: Equatable {
    case queued
    case rendering
    case finished
    case cancelled
    case failed

    var label: String {
        switch self {
        case .queued: "Ready"
        case .rendering: "Rendering"
        case .finished: "Finished"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .rendering: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .queued: .secondary
        case .rendering: .accentColor
        case .finished: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}
