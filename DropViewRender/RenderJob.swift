import SwiftUI

struct RenderJob: Identifiable {
    let id: UUID
    let inputURL: URL
    var outputURL: URL
    var packageSummary: String?
    var overridesResolution: Bool
    var qualityProfile: RenderQualityProfile = .recommended
    var usesDenoising = true
    var usesAdaptiveSampling = true
    var noiseThreshold = 0.01
    let sourceSamples: Int
    let sourceBounces: Int
    let sourceTransmissionBounces: Int
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
    var renderStartedUptime: TimeInterval?
    var renderDuration: TimeInterval?

    var elapsedRenderTime: TimeInterval? {
        if let renderDuration { return renderDuration }
        guard let renderStartedUptime else { return nil }
        return max(0, ProcessInfo.processInfo.systemUptime - renderStartedUptime)
    }

    var formattedRenderTime: String {
        let seconds = Int(elapsedRenderTime ?? 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    init(inputURL: URL, manifest: DVRenderManifest?) {
        id = UUID()
        self.inputURL = inputURL
        outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(inputURL.deletingPathExtension().lastPathComponent)-cycles.png")
        overridesResolution = false
        width = manifest?.renderSize?.width ?? 1_280
        height = manifest?.renderSize?.height ?? 720
        samples = manifest?.renderJob?.samples ?? 64
        bounces = manifest?.renderJob?.bounces ?? 6
        transmissionBounces = manifest?.renderJob?.transmissiveBounces ?? 10
        sourceSamples = samples
        sourceBounces = bounces
        sourceTransmissionBounces = transmissionBounces
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

enum RenderQualityProfile: String, CaseIterable, Identifiable {
    case recommended
    case custom

    var id: String { rawValue }
    var label: String { self == .recommended ? "Recommended" : "Custom" }
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
