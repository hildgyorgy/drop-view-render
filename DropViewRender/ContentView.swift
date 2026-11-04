import SwiftUI
import UniformTypeIdentifiers
import SafariServices

struct ContentView: View {
    @EnvironmentObject private var model: RenderQueueModel
    @EnvironmentObject private var bridge: BrowserBridge
    @State private var isDropTargeted = false
    @State private var safariExtensionError: String?

    var body: some View {
        NavigationSplitView {
            jobSidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Text(bridge.status)
                    ForEach(bridge.connectedOrigins, id: \.self) { Text($0) }
                    Button("Disconnect Browsers") { bridge.revokeSessions() }
                        .disabled(bridge.connectedOrigins.isEmpty)
                    Divider()
                    Button("Set Up Chrome / Edge…") {
                        BrowserExtensionSetup.install()
                    }
                    Button("Safari Extension Settings…") {
                        SFSafariApplication.showPreferencesForExtension(
                            withIdentifier: "com.hildgyorgy.DropViewRender.SafariExtension"
                        ) { error in
                            DispatchQueue.main.async { safariExtensionError = error?.localizedDescription }
                        }
                    }
                    if let safariExtensionError { Text(safariExtensionError) }
                } label: {
                    Label("Browser Bridge", systemImage: "network")
                }
                Button {
                    model.openFiles()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }

                Button {
                    model.startQueue()
                } label: {
                    Label("Render", systemImage: "play.fill")
                }
                .disabled(!model.canStart)
                .help("Render the selected job and pending jobs. Completed jobs can be rendered again with this button.")

                Button {
                    model.cancelRender()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!model.isRendering && model.preparingBlenderJobID == nil)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.acceptDrop(providers)
        }
        .onOpenURL { url in
            model.add([url])
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var jobSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedJobID) {
                ForEach(model.jobs) { job in
                    JobRow(job: job)
                        .tag(job.id)
                        .contextMenu {
                            Button("Show Input in Finder") {
                                model.reveal(job.inputURL)
                            }
                            if job.state == .finished {
                                Button("Show Output in Finder") {
                                    model.reveal(job.outputURL)
                                }
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                model.remove(job.id)
                            }
                            .disabled(job.state == .rendering || model.preparingBlenderJobID == job.id)
                        }
                }
            }
            .overlay {
                if model.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("Drop files here", systemImage: "square.and.arrow.down")
                    } description: {
                        Text("Add one or more GLB or .dvrender files.")
                    } actions: {
                        Button("Open Files…") {
                            model.openFiles()
                        }
                    }
                }
            }

            Divider()

            HStack {
                Image(systemName: model.blender.executableURL == nil ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .foregroundStyle(model.blender.executableURL == nil ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.blender.title)
                        .font(.caption.weight(.semibold))
                    Text(model.blender.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Choose…") {
                    model.chooseBlender()
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 400)
    }

    @ViewBuilder
    private var detail: some View {
        if let binding = model.selectedJobBinding {
            JobDetail(job: binding)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Drop & View Render")
                    .font(.title2.weight(.semibold))
                Text("Add a GLB or .dvrender file to prepare a Cycles render.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    let job: RenderJob

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = job.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 48)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(job.thumbnail == nil ? "No preview" : "Saved scene preview")
            Image(systemName: job.state.symbol)
                .foregroundStyle(job.state.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName ?? job.inputURL.lastPathComponent)
                    .lineLimit(1)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.elapsedRenderTime != nil {
                    RenderTimeLabel(job: job, compact: true)
                }
            }
            Spacer()
            if job.state == .rendering {
                if let progress = job.progress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct JobDetail: View {
    @EnvironmentObject private var model: RenderQueueModel
    @Binding var job: RenderJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                if let settings = job.lastRunSettings {
                    GroupBox(job.state == .rendering ? "Current render settings" : "Last run settings") {
                        Text(settings.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                if job.lastRunSettings != nil && job.state != .rendering {
                    Text("Next render settings")
                        .font(.headline)
                }
                resolution
                quality
                output
                if !job.log.isEmpty {
                    log
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.displayName ?? job.inputURL.lastPathComponent)
                    .font(.title2.weight(.semibold))
                Text(job.inputURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let summary = job.packageSummary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if job.elapsedRenderTime != nil {
                    RenderTimeLabel(job: job)
                }
                if let error = job.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            Spacer()
            Button("Remove", role: .destructive) {
                model.remove(job.id)
            }
            .disabled(job.state == .rendering || model.preparingBlenderJobID == job.id)
        }
    }

    private var quality: some View {
        GroupBox("Render quality") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Profile", selection: $job.qualityProfile) {
                    ForEach(RenderQualityProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(job.state == .rendering)

                if job.qualityProfile == .recommended {
                    LabeledContent("Maximum samples", value: String(job.sourceSamples))
                    LabeledContent("Bounces", value: String(job.sourceBounces))
                    LabeledContent("Transmission bounces", value: String(job.sourceTransmissionBounces))
                    LabeledContent("Denoise", value: "On")
                    LabeledContent("Adaptive sampling", value: "On · noise threshold \(RenderJob.recommendedNoiseThreshold)")
                    Text("Uses the source sample count as a maximum. Clean pixels may finish earlier; denoising runs after sampling. Bounce limits are preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text(job.usesAdaptiveSampling ? "Maximum samples" : "Samples")
                            IntegerField(value: $job.samples, range: 1...100_000)
                        }
                        GridRow {
                            Text("Bounces")
                            IntegerField(value: $job.bounces, range: 1...64)
                        }
                        GridRow {
                            Text("Transmission bounces")
                            IntegerField(value: $job.transmissionBounces, range: 1...64)
                        }
                    }
                    .disabled(job.state == .rendering)
                    Toggle("Denoise", isOn: $job.usesDenoising)
                        .disabled(job.state == .rendering)
                    Toggle("Adaptive sampling", isOn: $job.usesAdaptiveSampling)
                        .disabled(job.state == .rendering)
                    if job.usesAdaptiveSampling {
                        Picker("Noise threshold", selection: $job.noiseThreshold) {
                            Text("0.1 — faster").tag(0.1)
                            Text("0.03 — recommended").tag(0.03)
                            Text("0.01").tag(0.01)
                            Text("0.003").tag(0.003)
                            Text("0.001 — cleaner").tag(0.001)
                        }
                        .disabled(job.state == .rendering)
                    }
                    Text(job.usesAdaptiveSampling
                         ? "Samples is an upper limit. A lower noise threshold asks for a cleaner image and may take longer."
                         : "Every pixel receives the requested sample count. Turn denoise off too for a fixed-sample RAW comparison.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle("Show HDRI background", isOn: $job.showsHDRIBackground)
                    .disabled(job.state == .rendering)
                Text(job.showsHDRIBackground
                     ? "Show the environment image behind the model."
                     : "Keep HDRI lighting and reflections, but use a neutral background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var resolution: some View {
        GroupBox("Resolution") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Override source/default resolution", isOn: $job.overridesResolution)
                HStack {
                    IntegerField(value: $job.width, range: 1...16_384)
                    Text("×").foregroundStyle(.secondary)
                    IntegerField(value: $job.height, range: 1...16_384)
                    Text("px").foregroundStyle(.secondary)
                }
                .disabled(!job.overridesResolution)
                Text("Resolution is independent of the quality profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(job.state == .rendering)
            .padding(.top, 6)
        }
    }

    private var output: some View {
        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Format", value: "PNG")
                LabeledContent("Destination") {
                    Text(job.outputURL.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") {
                        model.chooseOutput(for: job.id)
                    }
                    .disabled(job.state == .rendering)
                    if job.state == .finished {
                        Button("Show in Finder") {
                            model.reveal(job.outputURL)
                        }
                    }
                    Button(model.preparingBlenderJobID == job.id ? "Preparing Blender…" : "View in Blender") {
                        model.viewInBlender(job.id)
                    }
                    .disabled(!job.isInputValid || model.blender.executableURL == nil
                              || model.isRendering || model.preparingBlenderJobID != nil)
                    .help("Opens the prepared scene in a new Blender instance. Uses last-run settings for rendered jobs; current settings for new jobs.")
                }
                if let error = job.blenderViewError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        }
    }

    private var log: some View {
        GroupBox("Blender output") {
            ScrollView {
                Text(job.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
    }
}

private struct RenderTimeLabel: View {
    let job: RenderJob
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("\(job.state == .rendering ? "Elapsed" : "Total time"): \(job.formattedRenderTime)")
                .font(compact ? .caption2.monospacedDigit() : .callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct IntegerField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
    }
}
