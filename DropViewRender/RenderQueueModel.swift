import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RenderQueueModel: ObservableObject {
    @Published var jobs: [RenderJob] = []
    @Published var selectedJobID: UUID?
    @Published var blender: BlenderInstallation = BlenderLocator.discover()
    @Published private(set) var isRendering = false

    private struct ActiveRun {
        let jobID: UUID
        let stagedOutputURL: URL
        let temporaryRootURL: URL
        let activity: NSObjectProtocol
        var terminationStatus: Int32?
        var outputClosed = false
        var readySeen = false
    }

    private let outputReadQueue = DispatchQueue(label: "com.hildgyorgy.DropViewRender.output")
    private var process: Process?
    private var outputPipe: Pipe?
    private var activeRun: ActiveRun?
    private var queueShouldContinue = false
    private var cancellationRequestedForJobID: UUID?
    private var terminationCompletion: (() -> Void)?
    private var terminateWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?

    private static let progressExpression = try! NSRegularExpression(
        pattern: #"(?:DVR_PROGRESS|Sample)\s+(\d+)/(\d+)"#
    )

    var canStart: Bool {
        blender.executableURL != nil
            && !isRendering
            && !jobsToStart.isEmpty
    }

    private var jobsToStart: [RenderJob] {
        jobs.filter {
            $0.isInputValid && ($0.state == .queued || $0.state == .failed
                || $0.state == .cancelled || ($0.id == selectedJobID && $0.state == .finished))
        }
    }

    var selectedJobBinding: Binding<RenderJob>? {
        guard let selectedJobID,
              let initial = jobs.first(where: { $0.id == selectedJobID }) else {
            return nil
        }
        return Binding(
            get: { self.jobs.first(where: { $0.id == selectedJobID }) ?? initial },
            set: { updated in
                guard let index = self.jobs.firstIndex(where: { $0.id == selectedJobID }) else { return }
                self.jobs[index] = updated
            }
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
        let supported = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !supported.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [(Int, URL)] = []
        for (index, provider) in supported.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                lock.lock()
                loaded.append((index, url))
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.add(loaded.sorted { $0.0 < $1.0 }.map(\.1))
        }
        return true
    }

    func add(_ urls: [URL]) {
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let fileExtension = canonical.pathExtension.lowercased()
            guard fileExtension == "glb" || fileExtension == "dvrender",
                  !jobs.contains(where: { $0.inputURL == canonical }) else {
                continue
            }

            var manifest: DVRenderManifest?
            var validationError: String?
            do {
                if fileExtension == "dvrender" {
                    manifest = try RenderInputValidator.readPackage(at: canonical)
                } else {
                    try RenderInputValidator.validateGLB(at: canonical)
                }
            } catch {
                validationError = error.localizedDescription
            }

            var job = RenderJob(inputURL: canonical, manifest: manifest)
            job.outputURL = availableDefaultOutput(for: job)
            if let validationError {
                job.state = .failed
                job.errorMessage = validationError
                job.isInputValid = false
            }
            jobs.append(job)
            selectedJobID = job.id
        }
    }

    func remove(_ id: UUID) {
        guard id != activeRun?.jobID else { return }
        jobs.removeAll { $0.id == id }
        if selectedJobID == id { selectedJobID = jobs.first?.id }
    }

    func chooseBlender() {
        if let selection = BlenderLocator.choose() {
            blender = selection
        }
    }

    func chooseOutput(for id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state != .rendering else { return }
        let panel = NSSavePanel()
        panel.title = "Choose PNG destination"
        panel.nameFieldStringValue = job.outputURL.lastPathComponent
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url,
              let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state != .rendering else { return }
        let output = selected.pathExtension.lowercased() == "png"
            ? selected
            : selected.appendingPathExtension("png")
        jobs[index].outputURL = output
        jobs[index].overwriteApproved = FileManager.default.fileExists(atPath: output.path)
        jobs[index].errorMessage = nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func startQueue() {
        guard canStart, process == nil else { return }
        let candidates = jobsToStart
        var approved = Set<UUID>()
        for job in candidates where !job.overwriteApproved
            && FileManager.default.fileExists(atPath: job.outputURL.path) {
            let alert = NSAlert()
            alert.messageText = "Replace existing render?"
            alert.informativeText = "\(job.outputURL.path)\n\nThe existing image will be replaced only after the new render completes successfully. Use Choose… to save a separate comparison image."
            alert.addButton(withTitle: "Replace and Render")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            approved.insert(job.id)
        }
        let candidateIDs = Set(candidates.map(\.id))
        for index in jobs.indices where candidateIDs.contains(jobs[index].id) {
            jobs[index].state = .queued
            jobs[index].errorMessage = nil
            if approved.contains(jobs[index].id) { jobs[index].overwriteApproved = true }
        }
        queueShouldContinue = true
        startNextJob(preferredID: selectedJobID)
    }

    func cancelRender() {
        queueShouldContinue = false
        requestCancellation()
    }

    func stopForApplicationTermination(completion: @escaping () -> Void) {
        guard isRendering else {
            completion()
            return
        }
        queueShouldContinue = false
        terminationCompletion = completion
        requestCancellation()
    }

    private func startNextJob(preferredID: UUID? = nil) {
        guard queueShouldContinue,
              let blenderURL = blender.executableURL,
              let index = jobs.firstIndex(where: { $0.id == preferredID && $0.state == .queued })
                ?? jobs.firstIndex(where: { $0.state == .queued }) else {
            return
        }
        jobs[index].renderStartedUptime = nil
        jobs[index].renderDuration = nil
        guard let adapterURL = Bundle.main.url(forResource: "render_glb", withExtension: "py") else {
            failJob(at: index, message: "The bundled Blender adapter is missing.")
            continueQueueSoon()
            return
        }

        let job = jobs[index]
        let prepared: (staged: URL, temporaryRoot: URL)
        do {
            prepared = try prepareOutput(for: job)
        } catch {
            failJob(at: index, message: error.localizedDescription)
            continueQueueSoon()
            return
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = blenderURL
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        var arguments = [
            "--background", "--factory-startup", "--python-exit-code", "1",
            "--python", adapterURL.path, "--", job.inputURL.path,
            "--output", prepared.staged.path
        ]
        if job.overridesResolution {
            arguments += [
                "--width", String(job.width),
                "--height", String(job.height)
            ]
        }
        if job.qualityProfile == .custom {
            arguments += [
                "--samples", String(job.samples),
                "--bounces", String(job.bounces),
                "--transmission-bounces", String(job.transmissionBounces)
            ]
        }
        arguments.append(job.qualityProfile == .recommended || job.usesDenoising
                         ? "--denoise" : "--no-denoise")
        let adaptive = job.qualityProfile == .recommended || job.usesAdaptiveSampling
        arguments.append(adaptive ? "--adaptive-sampling" : "--no-adaptive-sampling")
        arguments += ["--noise-threshold", String(job.qualityProfile == .recommended ? 0.01 : job.noiseThreshold)]
        if !job.showsHDRIBackground {
            arguments.append("--hide-hdri-background")
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = prepared.temporaryRoot.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Rendering \(job.inputURL.lastPathComponent)"
        )
        activeRun = ActiveRun(
            jobID: job.id,
            stagedOutputURL: prepared.staged,
            temporaryRootURL: prepared.temporaryRoot,
            activity: activity
        )
        self.process = process
        outputPipe = pipe
        isRendering = true
        cancellationRequestedForJobID = nil
        jobs[index].state = .rendering
        jobs[index].renderStartedUptime = ProcessInfo.processInfo.systemUptime
        jobs[index].progress = nil
        jobs[index].log = ""
        jobs[index].errorMessage = nil

        process.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                self?.processDidTerminate(job.id, status: completed.terminationStatus)
            }
        }

        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            readOutput(from: pipe.fileHandleForReading, for: job.id)
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
            finishLaunchFailure(job.id, message: error.localizedDescription)
        }
    }

    private func readOutput(from handle: FileHandle, for jobID: UUID) {
        outputReadQueue.async { [weak self] in
            var buffer = Data()
            do {
                while let data = try handle.read(upToCount: 16_384), !data.isEmpty {
                    buffer.append(data)
                    let lines = Self.extractLines(from: &buffer)
                    if !lines.isEmpty {
                        DispatchQueue.main.async { self?.consume(lines, for: jobID) }
                    }
                }
                if !buffer.isEmpty {
                    let finalLine = String(decoding: buffer, as: UTF8.self)
                    DispatchQueue.main.async { self?.consume([finalLine], for: jobID) }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.consume(["Output stream error: \(error.localizedDescription)"], for: jobID)
                }
            }
            try? handle.close()
            DispatchQueue.main.async { self?.outputDidClose(for: jobID) }
        }
    }

    private nonisolated static func extractLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let boundary = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let separator = buffer[boundary]
            let line = Data(buffer[..<boundary])
            buffer.removeSubrange(...boundary)
            if separator == 13, buffer.first == 10 { buffer.removeFirst() }
            lines.append(String(decoding: line, as: UTF8.self))
        }
        return lines
    }

    private func consume(_ lines: [String], for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), activeRun?.jobID == id else { return }
        let text = lines.joined(separator: "\n") + "\n"
        jobs[index].log.append(text)
        if jobs[index].log.count > 100_000 {
            jobs[index].log = String(jobs[index].log.suffix(100_000))
        }

        for line in lines {
            if line.contains("[Drop & View Cycles] READY:") {
                activeRun?.readySeen = true
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = Self.progressExpression.firstMatch(in: line, range: range),
                  let currentRange = Range(match.range(at: 1), in: line),
                  let totalRange = Range(match.range(at: 2), in: line),
                  let current = Double(line[currentRange]),
                  let total = Double(line[totalRange]), total > 0 else { continue }
            jobs[index].progress = min(max(current / total, 0), 1)
        }
    }

    private func outputDidClose(for id: UUID) {
        guard activeRun?.jobID == id else { return }
        activeRun?.outputClosed = true
        finishIfReady()
    }

    private func processDidTerminate(_ id: UUID, status: Int32) {
        guard activeRun?.jobID == id else { return }
        activeRun?.terminationStatus = status
        finishIfReady()
    }

    private func finishIfReady() {
        guard let run = activeRun,
              run.outputClosed,
              let status = run.terminationStatus,
              let index = jobs.firstIndex(where: { $0.id == run.jobID }) else { return }

        terminateWorkItem?.cancel()
        killWorkItem?.cancel()
        terminateWorkItem = nil
        killWorkItem = nil

        let cancelled = cancellationRequestedForJobID == run.jobID
        do {
            if status == 0 && run.readySeen {
                try finalizeOutput(for: jobs[index], stagedURL: run.stagedOutputURL)
                jobs[index].state = .finished
                jobs[index].progress = 1
                jobs[index].overwriteApproved = false
            } else if cancelled {
                jobs[index].state = .cancelled
                jobs[index].errorMessage = "Rendering was cancelled."
            } else if status == 0 {
                jobs[index].state = .failed
                jobs[index].errorMessage = "Blender exited without confirming a completed render."
            } else {
                jobs[index].state = .failed
                jobs[index].errorMessage = "Blender exited with status \(status). See Blender output for details."
            }
        } catch {
            jobs[index].state = .failed
            jobs[index].errorMessage = error.localizedDescription
        }

        cleanup(run)
        let shouldContinue = queueShouldContinue && !cancelled
        let completion = terminationCompletion
        terminationCompletion = nil
        if let completion {
            queueShouldContinue = false
            completion()
        } else if shouldContinue {
            startNextJob()
        }
    }

    private func requestCancellation() {
        guard let process, process.isRunning, let id = activeRun?.jobID else { return }
        cancellationRequestedForJobID = id
        process.interrupt()

        let terminate = DispatchWorkItem { [weak self, weak process] in
            guard let self, self.process === process, process?.isRunning == true else { return }
            process?.terminate()
        }
        terminateWorkItem = terminate
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: terminate)

        let kill = DispatchWorkItem { [weak self, weak process] in
            guard let self, self.process === process, let process, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        killWorkItem = kill
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: kill)
    }

    private func prepareOutput(for job: RenderJob) throws -> (staged: URL, temporaryRoot: URL) {
        let fileManager = FileManager.default
        let destination = job.outputURL.standardizedFileURL
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let conflicts = jobs.contains {
            $0.id != job.id
                && $0.outputURL.standardizedFileURL == destination
                && $0.state != .cancelled
                && $0.state != .failed
        }
        guard !conflicts else { throw RenderOutputError.duplicateDestination }
        guard !fileManager.fileExists(atPath: destination.path) || job.overwriteApproved else {
            throw RenderOutputError.destinationExists
        }

        let probe = directory.appendingPathComponent(".drop-view-render-write-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()) else {
            throw RenderOutputError.directoryNotWritable
        }
        try? fileManager.removeItem(at: probe)

        let staged = directory.appendingPathComponent(".drop-view-render-\(job.id.uuidString).png")
        if fileManager.fileExists(atPath: staged.path) { try fileManager.removeItem(at: staged) }
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("drop-view-render-job-\(job.id.uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: temporaryRoot.path) { try fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        return (staged, temporaryRoot)
    }

    private func finalizeOutput(for job: RenderJob, stagedURL: URL) throws {
        let fileManager = FileManager.default
        let values = try stagedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw RenderOutputError.missingStagedOutput
        }
        if fileManager.fileExists(atPath: job.outputURL.path) {
            guard job.overwriteApproved else { throw RenderOutputError.destinationExists }
            _ = try fileManager.replaceItemAt(job.outputURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: job.outputURL)
        }
    }

    private func cleanup(_ run: ActiveRun) {
        if let index = jobs.firstIndex(where: { $0.id == run.jobID }),
           let started = jobs[index].renderStartedUptime {
            let duration = max(0, ProcessInfo.processInfo.systemUptime - started)
            jobs[index].renderDuration = duration
            jobs[index].log.append("\n[Drop & View Render] Total time (including preparation and denoise): \(jobs[index].formattedRenderTime)\n")
        }
        ProcessInfo.processInfo.endActivity(run.activity)
        if FileManager.default.fileExists(atPath: run.stagedOutputURL.path) {
            try? FileManager.default.removeItem(at: run.stagedOutputURL)
        }
        try? FileManager.default.removeItem(at: run.temporaryRootURL)
        process = nil
        outputPipe = nil
        activeRun = nil
        cancellationRequestedForJobID = nil
        isRendering = false
    }

    private func finishLaunchFailure(_ id: UUID, message: String) {
        guard let run = activeRun, run.jobID == id,
              let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed
        jobs[index].errorMessage = message
        cleanup(run)
        continueQueueSoon()
    }

    private func failJob(at index: Int, message: String) {
        jobs[index].state = .failed
        jobs[index].errorMessage = message
    }

    private func continueQueueSoon() {
        guard queueShouldContinue else { return }
        DispatchQueue.main.async { [weak self] in self?.startNextJob() }
    }

    private func availableDefaultOutput(for job: RenderJob) -> URL {
        let preferred = job.outputURL
        guard jobs.contains(where: { $0.outputURL.standardizedFileURL == preferred.standardizedFileURL }) else {
            return preferred
        }
        let stem = job.inputURL.deletingPathExtension().lastPathComponent
        let kind = job.inputURL.pathExtension.lowercased()
        return job.inputURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(kind)-cycles.png")
    }
}

private enum RenderOutputError: LocalizedError {
    case duplicateDestination
    case destinationExists
    case directoryNotWritable
    case missingStagedOutput

    var errorDescription: String? {
        switch self {
        case .duplicateDestination:
            "Another job uses the same output destination. Choose a different PNG path."
        case .destinationExists:
            "The output PNG already exists. Use Choose… to confirm replacement or select a different path."
        case .directoryNotWritable:
            "The output folder is not writable. Choose another destination."
        case .missingStagedOutput:
            "Blender reported completion but did not produce a valid PNG."
        }
    }
}

extension UTType {
    static let glb = UTType(filenameExtension: "glb") ?? .data
    static let dvRender = UTType(importedAs: "com.hildgyorgy.drop-view-render-package", conformingTo: .data)
}
