import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RenderQueueModel: ObservableObject {
    @Published var jobs: [RenderJob] = []
    @Published var selectedJobID: UUID?
    @Published var blender: BlenderInstallation = BlenderLocator.discover()

    private var process: Process?
    private var outputPipe: Pipe?
    private var activeJobID: UUID?
    private var cancellationRequested = false

    var isRendering: Bool { process?.isRunning == true }
    var canStart: Bool {
        blender.executableURL != nil
            && !isRendering
            && jobs.contains {
                $0.isInputValid && ($0.state == .queued || $0.state == .failed || $0.state == .cancelled)
            }
    }

    var selectedJobBinding: Binding<RenderJob>? {
        guard let selectedJobID,
              let index = jobs.firstIndex(where: { $0.id == selectedJobID }) else {
            return nil
        }
        return Binding(
            get: { self.jobs[index] },
            set: { self.jobs[index] = $0 }
        )
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add render files"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.glb, .dvRender]
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in self.add([url]) }
            }
        }
        return accepted
    }

    func add(_ urls: [URL]) {
        for url in urls {
            let canonical = url.standardizedFileURL
            let fileExtension = canonical.pathExtension.lowercased()
            guard fileExtension == "glb" || fileExtension == "dvrender",
                  !jobs.contains(where: { $0.inputURL.standardizedFileURL == canonical }) else {
                continue
            }

            var manifest: DVRenderManifest?
            var jobError: String?
            if fileExtension == "dvrender" {
                do {
                    manifest = try DVRenderManifestReader.read(from: canonical)
                } catch {
                    jobError = error.localizedDescription
                }
            }
            var job = RenderJob(inputURL: canonical, manifest: manifest)
            if let jobError {
                job.state = .failed
                job.errorMessage = jobError
                job.isInputValid = false
            }
            jobs.append(job)
            selectedJobID = job.id
        }
    }

    func remove(_ id: UUID) {
        guard id != activeJobID else { return }
        jobs.removeAll { $0.id == id }
        if selectedJobID == id { selectedJobID = jobs.first?.id }
    }

    func chooseBlender() {
        if let selection = BlenderLocator.choose() {
            blender = selection
        }
    }

    func chooseOutput(for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Choose PNG destination"
        panel.nameFieldStringValue = jobs[index].outputURL.lastPathComponent
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        jobs[index].outputURL = url.pathExtension.lowercased() == "png"
            ? url
            : url.appendingPathExtension("png")
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func startQueue() {
        guard process == nil else { return }
        for index in jobs.indices
            where jobs[index].isInputValid
                && (jobs[index].state == .failed || jobs[index].state == .cancelled) {
            jobs[index].state = .queued
        }
        startNextJob()
    }

    func cancelRender() {
        guard let process, process.isRunning else { return }
        cancellationRequested = true
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    private func startNextJob() {
        guard let blenderURL = blender.executableURL,
              let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            return
        }
        guard let adapterURL = Bundle.main.url(forResource: "render_glb", withExtension: "py") else {
            jobs[index].state = .failed
            jobs[index].errorMessage = "The bundled Blender adapter is missing."
            return
        }

        let job = jobs[index]
        let process = Process()
        let pipe = Pipe()
        process.executableURL = blenderURL
        process.standardOutput = pipe
        process.standardError = pipe

        var arguments = [
            "--background", "--factory-startup", "--python-exit-code", "1",
            "--python", adapterURL.path, "--", job.inputURL.path,
            "--output", job.outputURL.path
        ]
        if job.overridesSourceSettings {
            arguments += [
                "--width", String(job.width),
                "--height", String(job.height),
                "--samples", String(job.samples),
                "--bounces", String(job.bounces),
                "--transmission-bounces", String(job.transmissionBounces)
            ]
        }
        if !job.showsHDRIBackground {
            arguments.append("--hide-hdri-background")
        }
        process.arguments = arguments

        jobs[index].state = .rendering
        jobs[index].progress = nil
        jobs[index].log = ""
        jobs[index].errorMessage = nil
        activeJobID = job.id
        cancellationRequested = false
        self.process = process
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text, for: job.id) }
        }
        process.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async { self?.finish(job.id, status: completed.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            outputPipe = nil
            activeJobID = nil
            jobs[index].state = .failed
            jobs[index].errorMessage = error.localizedDescription
        }
    }

    private func consume(_ text: String, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].log.append(text)
        if jobs[index].log.count > 100_000 {
            jobs[index].log.removeFirst(jobs[index].log.count - 100_000)
        }

        let pattern = #"Sample\s+(\d+)/(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let currentRange = Range(match.range(at: 1), in: text),
           let totalRange = Range(match.range(at: 2), in: text),
           let current = Double(text[currentRange]),
           let total = Double(text[totalRange]), total > 0 {
            jobs[index].progress = min(max(current / total, 0), 1)
        }
    }

    private func finish(_ id: UUID, status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if cancellationRequested {
                jobs[index].state = .cancelled
                jobs[index].errorMessage = "Rendering was cancelled."
            } else if status == 0 && FileManager.default.fileExists(atPath: jobs[index].outputURL.path) {
                jobs[index].state = .finished
                jobs[index].progress = 1
            } else {
                jobs[index].state = .failed
                jobs[index].errorMessage = "Blender exited with status \(status). See Blender output for details."
            }
        }
        process = nil
        outputPipe = nil
        activeJobID = nil
        cancellationRequested = false
        startNextJob()
    }
}

extension UTType {
    static let glb = UTType(filenameExtension: "glb") ?? .data
    static let dvRender = UTType(importedAs: "com.hildgyorgy.drop-view-render-package", conformingTo: .data)
}
