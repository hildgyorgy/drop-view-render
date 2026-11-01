import SwiftUI

struct RenderJob: Identifiable {
    static let recommendedNoiseThreshold = 0.03
    let id: UUID
    let inputURL: URL
    var outputURL: URL
    var packageSummary: String?
    var overridesResolution: Bool
    var qualityProfile: RenderQualityProfile = .recommended
    var usesDenoising = true
    var usesAdaptiveSampling = true
    var noiseThreshold = RenderJob.recommendedNoiseThreshold
    let sourceWidth: Int
    let sourceHeight: Int
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
    var lastRunSettings: RenderSettingsSnapshot?

    var resolvedSettings: RenderSettingsSnapshot {
        let recommended = qualityProfile == .recommended
        return RenderSettingsSnapshot(
            profile: qualityProfile,
            width: overridesResolution ? width : sourceWidth,
            height: overridesResolution ? height : sourceHeight,
            samples: recommended ? sourceSamples : samples,
            bounces: recommended ? sourceBounces : bounces,
            transmissionBounces: recommended ? sourceTransmissionBounces : transmissionBounces,
            denoise: recommended || usesDenoising,
            adaptive: recommended || usesAdaptiveSampling,
            noiseThreshold: recommended ? Self.recommendedNoiseThreshold : noiseThreshold,
            showsHDRIBackground: showsHDRIBackground,
            outputURL: outputURL
        )
    }

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
        sourceWidth = width
        sourceHeight = height
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

struct RenderSettingsSnapshot: Equatable {
    let profile: RenderQualityProfile
    let width: Int
    let height: Int
    let samples: Int
    let bounces: Int
    let transmissionBounces: Int
    let denoise: Bool
    let adaptive: Bool
    let noiseThreshold: Double
    let showsHDRIBackground: Bool
    let outputURL: URL

    var summary: String {
        let sampling = adaptive
            ? "Adaptive ON · threshold \(noiseThreshold) · maximum \(samples) samples"
            : "Adaptive OFF · fixed \(samples) samples"
        return "\(profile.label) · \(width)×\(height)\n\(sampling)\nDenoise \(denoise ? "ON" : "OFF") · bounces \(bounces) · transmission bounces \(transmissionBounces)\nHDRI background \(showsHDRIBackground ? "ON" : "OFF")\n\(outputURL.path)"
    }

    var adapterArguments: [String] {
        var arguments = [
            "--width", String(width), "--height", String(height),
            "--samples", String(samples), "--bounces", String(bounces),
            "--transmission-bounces", String(transmissionBounces),
            denoise ? "--denoise" : "--no-denoise",
            adaptive ? "--adaptive-sampling" : "--no-adaptive-sampling",
            "--noise-threshold", String(noiseThreshold)
        ]
        if !showsHDRIBackground { arguments.append("--hide-hdri-background") }
        return arguments
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
