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
    @Published private(set) var preparingBlenderJobID: UUID?
    // Test injection avoids launching a GUI during model smoke tests.
    var blenderSceneOpener: ((URL, URL) throws -> Void)?
    private var blenderViewProcess: Process?
    private var blenderViewCancelled = false

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
    private var singleJobID: UUID?
    private var pendingBrowserJobs: [UUID] = []
    private var browserQueuePaused = false
    private var submittedSettings: [UUID: RenderSettingsSnapshot] = [:]
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
            && preparingBlenderJobID == nil
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
        guard id != activeRun?.jobID, id != preparingBlenderJobID else { return }
        pendingBrowserJobs.removeAll { $0 == id }
        submittedSettings.removeValue(forKey: id)
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
        jobs[index].outputSeriesBaseURL = output
        jobs[index].overwriteApproved = FileManager.default.fileExists(atPath: output.path)
        jobs[index].errorMessage = nil
    }

    func reveal(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard let finderURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            workspace.activateFileViewerSelecting([url])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: finderURL, configuration: configuration) { application, _ in
            DispatchQueue.main.async {
                if let application {
                    NSApp.yieldActivation(to: application)
                    application.activate(options: .activateAllWindows)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func viewInBlender(_ id: UUID) {
        guard !isRendering, preparingBlenderJobID == nil,
              let blenderURL = blender.executableURL,
              let index = jobs.firstIndex(where: { $0.id == id && $0.isInputValid }) else { return }
        let job = jobs[index]
        let settings = job.lastRunSettings ?? submittedSettings[id] ?? job.resolvedSettings
        jobs[index].blenderViewError = nil
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hildgyorgy.DropViewRender/BlenderViews/\(UUID().uuidString)", isDirectory: true)
        let name = URL(fileURLWithPath: job.displayName ?? job.inputURL.lastPathComponent)
            .deletingPathExtension().lastPathComponent
        let sceneURL = root.appendingPathComponent("\(name).blend")
        do {
            guard let adapter = Bundle.main.url(forResource: "render_glb", withExtension: "py") else {
                throw CocoaError(.fileNoSuchFile)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let process = Process()
            let pipe = Pipe()
            process.executableURL = blenderURL
            process.arguments = ["--background", "--factory-startup", "--python-exit-code", "1",
                                 "--python", adapter.path, "--", job.inputURL.path,
                                 "--output", settings.outputURL.path,
                                 "--save-blend", sceneURL.path, "--prepare-only"] + settings.adapterArguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PYTHONIOENCODING"] = "utf-8"
            process.environment = environment
            try process.run()
            try? pipe.fileHandleForWriting.close()
            blenderViewProcess = process
            preparingBlenderJobID = id
            blenderViewCancelled = false
            let handle = pipe.fileHandleForReading
            outputReadQueue.async { [weak self] in
                var tail = Data()
                do {
                    while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
                        tail.append(chunk)
                        if tail.count > 65_536 { tail = Data(tail.suffix(65_536)) }
                    }
                } catch { tail.append(Data("\n\(error.localizedDescription)".utf8)) }
                try? handle.close()
                process.waitUntilExit()
                let output = String(decoding: tail, as: UTF8.self)
                DispatchQueue.main.async {
                    self?.finishBlenderPreparation(id, status: process.terminationStatus,
                                                  output: output, sceneURL: sceneURL, blenderURL: blenderURL)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            jobs[index].blenderViewError = "Could not prepare Blender scene: \(error.localizedDescription)"
        }
    }

    private func finishBlenderPreparation(_ id: UUID, status: Int32, output: String,
                                          sceneURL: URL, blenderURL: URL) {
        blenderViewProcess = nil
        preparingBlenderJobID = nil
        let completion = terminationCompletion
        if completion != nil { terminationCompletion = nil }
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            do {
                guard !blenderViewCancelled, completion == nil else { throw CocoaError(.userCancelled) }
                guard status == 0, output.contains("[Drop & View Cycles] SCENE_READY:") else {
                    throw NSError(domain: "DropViewRender", code: Int(status),
                                  userInfo: [NSLocalizedDescriptionKey: "Blender scene preparation failed (status \(status)).\n\(output.suffix(3000))"])
                }
                let handle = try FileHandle(forReadingFrom: sceneURL)
                let header = try handle.read(upToCount: 7)
                try handle.close()
                guard header == Data("BLENDER".utf8) else { throw CocoaError(.fileReadCorruptFile) }
                jobs[index].blenderSceneURL = sceneURL
                try openPreparedScene(sceneURL, blenderURL: blenderURL, jobID: id)
            } catch {
                jobs[index].blenderSceneURL = nil
                try? FileManager.default.removeItem(at: sceneURL.deletingLastPathComponent())
                jobs[index].blenderViewError = blenderViewCancelled
                    ? "Blender scene preparation was cancelled." : error.localizedDescription
            }
        }
        if let completion { completion() } else {
            startNextJob()
            startPendingBrowserJobIfIdle()
        }
    }

    private func openPreparedScene(_ url: URL, blenderURL: URL, jobID: UUID) throws {
        if let blenderSceneOpener { try blenderSceneOpener(url, blenderURL); return }
        let appURL = blenderURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else {
            throw NSError(domain: "DropViewRender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose Blender.app to open the scene in Blender."])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        guard let adapter = Bundle.main.url(forResource: "render_glb", withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        configuration.arguments = [url.path, "--python", adapter.path, "--", url.path, "--view-prepared"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    self.jobs[index].blenderViewError = "Could not open Blender: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelBlenderPreparation() {
        guard let process = blenderViewProcess else { return }
        blenderViewCancelled = true
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak process] in
            guard let self, self.blenderViewProcess === process, process?.isRunning == true else { return }
            process?.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self, weak process] in
            guard let self, self.blenderViewProcess === process, let process, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func startQueue() {
        guard canStart, process == nil else { return }
        singleJobID = nil
        pendingBrowserJobs.removeAll()
        browserQueuePaused = false
        let candidates = jobsToStart
        let candidateIDs = Set(candidates.map(\.id))
        for index in jobs.indices where candidateIDs.contains(jobs[index].id) {
            jobs[index].state = .queued
            jobs[index].errorMessage = nil
        }
        queueShouldContinue = true
        startNextJob(preferredID: selectedJobID)
    }

    /// Browser submissions run serially without starting unrelated local jobs.
    func acceptBrowserJob(at url: URL, manifest: DVRenderManifest, outputDirectory: URL) throws -> UUID {
        guard blender.executableURL != nil else { throw RenderOutputError.blenderUnavailable }
        var job = RenderJob(inputURL: url, manifest: manifest)
        let stem = URL(fileURLWithPath: manifest.fileName).deletingPathExtension().lastPathComponent
        job.displayName = "\(stem).dvrender"
        job.outputURL = outputDirectory.appendingPathComponent("\(stem)-cycles.png")
        jobs.append(job)
        let index = jobs.count - 1
        selectOutputForRun(at: index)
        submittedSettings[job.id] = jobs[index].resolvedSettings
        selectedJobID = job.id
        pendingBrowserJobs.append(job.id)
        browserQueuePaused = false
        startPendingBrowserJobIfIdle()
        return job.id
    }

    func browserJobStatus(_ id: UUID) -> [String: Any]? {
        guard let job = jobs.first(where: { $0.id == id }) else { return nil }
        var result: [String: Any] = ["id": id.uuidString, "state": String(describing: job.state),
                                   "elapsed": job.elapsedRenderTime ?? 0,
                                   "outputName": job.outputURL.lastPathComponent]
        if let progress = job.progress { result["progress"] = progress }
        if let position = pendingBrowserJobs.firstIndex(of: id) { result["queuePosition"] = position + 1 }
        if let error = job.errorMessage { result["error"] = error }
        if let settings = job.lastRunSettings ?? submittedSettings[id] {
            result["settings"] = ["width": settings.width, "height": settings.height,
                                  "samples": settings.samples, "bounces": settings.bounces,
                                  "transmissionBounces": settings.transmissionBounces,
                                  "denoise": settings.denoise, "adaptive": settings.adaptive,
                                  "noiseThreshold": settings.noiseThreshold]
        }
        return result
    }

    func cancelBrowserJob(_ id: UUID) -> Bool {
        if let position = pendingBrowserJobs.firstIndex(of: id),
           let index = jobs.firstIndex(where: { $0.id == id && $0.state == .queued }) {
            pendingBrowserJobs.remove(at: position)
            submittedSettings.removeValue(forKey: id)
            jobs[index].state = .cancelled
            jobs[index].errorMessage = "Rendering was cancelled before it started."
            return true
        }
        guard activeRun?.jobID == id else { return false }
        requestCancellation()
        return true
    }

    func revealBrowserJob(_ id: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .finished else { return false }
        reveal(job.outputURL)
        return true
    }

    func cancelRender() {
        browserQueuePaused = true
        queueShouldContinue = false
        if preparingBlenderJobID != nil { cancelBlenderPreparation(); return }
        requestCancellation()
    }

    func stopForApplicationTermination(completion: @escaping () -> Void) {
        browserQueuePaused = true
        if preparingBlenderJobID != nil {
            queueShouldContinue = false
            terminationCompletion = completion
            cancelBlenderPreparation()
            return
        }
        guard isRendering else {
            completion()
            return
        }
        queueShouldContinue = false
        terminationCompletion = completion
        requestCancellation()
    }

    private func startNextJob(preferredID: UUID? = nil) {
        guard !isRendering, preparingBlenderJobID == nil, process == nil, queueShouldContinue,
              let blenderURL = blender.executableURL else { return }
        let eligible: (RenderJob) -> Bool = { job in
            guard job.state == .queued else { return false }
            if let id = self.singleJobID { return job.id == id }
            return !self.pendingBrowserJobs.contains(job.id)
        }
        guard let index = jobs.firstIndex(where: { $0.id == preferredID && eligible($0) })
                ?? jobs.firstIndex(where: eligible) else {
            return
        }
        jobs[index].renderStartedUptime = nil
        jobs[index].renderDuration = nil
        guard let adapterURL = Bundle.main.url(forResource: "render_glb", withExtension: "py") else {
            failJob(at: index, message: "The bundled Blender adapter is missing.")
            continueQueueSoon()
            return
        }

        selectOutputForRun(at: index)
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
        var settings = submittedSettings.removeValue(forKey: job.id) ?? job.resolvedSettings
        settings.outputURL = job.outputURL
        arguments += settings.adapterArguments
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
        jobs[index].lastRunSettings = settings
        jobs[index].log = "[Drop & View Render] Requested settings:\n\(settings.summary)\n\n"
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
        if completion == nil { startPendingBrowserJobIfIdle() }
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
        if singleJobID == run.jobID {
            singleJobID = nil
            queueShouldContinue = false
        }
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
        submittedSettings.removeValue(forKey: jobs[index].id)
        jobs[index].state = .failed
        jobs[index].errorMessage = message
        if singleJobID == jobs[index].id {
            singleJobID = nil
            queueShouldContinue = false
        }
    }

    private func continueQueueSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.startNextJob()
            self?.startPendingBrowserJobIfIdle()
        }
    }

    private func startPendingBrowserJobIfIdle() {
        guard !isRendering, preparingBlenderJobID == nil, process == nil, !browserQueuePaused,
              blender.executableURL != nil else { return }
        pendingBrowserJobs.removeAll { id in !jobs.contains(where: { $0.id == id && $0.state == .queued }) }
        guard !pendingBrowserJobs.isEmpty else { return }
        let id = pendingBrowserJobs.removeFirst()
        singleJobID = id
        queueShouldContinue = true
        startNextJob(preferredID: id)
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

    private func selectOutputForRun(at index: Int) {
        let job = jobs[index]
        let base = job.outputSeriesBaseURL ?? job.outputURL
        jobs[index].outputSeriesBaseURL = base
        // Explicit replacement approved in NSSavePanel remains possible.
        guard !job.overwriteApproved else { return }
        let reserved = Set(jobs.filter { $0.id != job.id }.map { $0.outputURL.standardizedFileURL })
        let isRerender = job.lastRunSettings?.outputURL == job.outputURL
        if !isRerender && !reserved.contains(job.outputURL.standardizedFileURL)
            && !FileManager.default.fileExists(atPath: job.outputURL.path) { return }
        var number = 1
        while true {
            let stem = base.deletingPathExtension().lastPathComponent
            let name = "\(stem)-\(String(format: "%03d", number)).\(base.pathExtension)"
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if candidate != job.lastRunSettings?.outputURL
                && !reserved.contains(candidate.standardizedFileURL)
                && !FileManager.default.fileExists(atPath: candidate.path) {
                jobs[index].outputURL = candidate
                return
            }
            number += 1
        }
    }
}

private enum RenderOutputError: LocalizedError {
    case rendererBusy
    case blenderUnavailable
    case duplicateDestination
    case destinationExists
    case directoryNotWritable
    case missingStagedOutput

    var errorDescription: String? {
        switch self {
        case .rendererBusy: "The renderer is busy. Wait for the current render to finish."
        case .blenderUnavailable: "Choose Blender in Drop & View Render before submitting a job."
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
