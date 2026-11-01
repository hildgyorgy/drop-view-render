import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: RenderQueueModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            jobSidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
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

                Button {
                    model.cancelRender()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!model.isRendering)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            model.acceptDrop(providers)
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
                            .disabled(job.state == .rendering)
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
            Image(systemName: job.state.symbol)
                .foregroundStyle(job.state.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.inputURL.lastPathComponent)
                    .lineLimit(1)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text(job.inputURL.lastPathComponent)
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
            .disabled(job.state == .rendering)
        }
    }

    private var quality: some View {
        GroupBox("Render quality") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Override source/default render settings", isOn: $job.overridesSourceSettings)
                    .disabled(job.state == .rendering)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Resolution")
                        HStack {
                            IntegerField(value: $job.width, range: 1...16_384)
                            Text("×").foregroundStyle(.secondary)
                            IntegerField(value: $job.height, range: 1...16_384)
                        }
                    }
                    GridRow {
                        Text("Samples")
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
                .disabled(!job.overridesSourceSettings || job.state == .rendering)

                Text(job.overridesSourceSettings
                     ? "These exact values are passed to Blender; they are never reduced silently."
                     : "The adapter will use the .dvrender values, or its defaults for a plain GLB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
