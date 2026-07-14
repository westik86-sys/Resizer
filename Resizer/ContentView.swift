import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum ImportTarget {
        case input
        case outputDirectory

        var allowedContentTypes: [UTType] {
            switch self {
            case .input:
                [.mpeg4Movie, .quickTimeMovie]
            case .outputDirectory:
                [.folder]
            }
        }
    }

    @ObservedObject private var model: CompressionFeatureModel
    @AppStorage(CompressionPreferences.outputFilenameSuffixKey)
    private var filenameSuffix = CompressionPreferences.defaultOutputFilenameSuffix
    @AppStorage(CompressionPreferences.outputConflictPolicyKey)
    private var conflictPolicyRawValue =
        CompressionPreferences.defaultOutputConflictPolicy.rawValue

    @State private var importTarget: ImportTarget = .input
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isAdvancedSettingsExpanded = false
    @State private var isDiagnosticsExpanded = false

    init(model: CompressionFeatureModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            queueSidebar
                .navigationSplitViewColumnWidth(
                    min: 250,
                    ideal: 290,
                    max: 360
                )
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()

                if let message = model.validationMessage,
                   !model.jobs.isEmpty {
                    validationBanner(message)
                }

                ScrollView {
                    screenContent
                        .frame(maxWidth: 960)
                        .padding(28)
                        .frame(maxWidth: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 620)
        .toolbar {
            ToolbarItem {
                if !model.readyJobs.isEmpty {
                    Button {
                        Task {
                            await model.start(
                                filenameSuffix: validatedFilenameSuffix,
                                conflictPolicy: conflictPolicy
                            )
                        }
                    } label: {
                        Label(
                            "Start \(model.readyJobs.count)",
                            systemImage: "play.fill"
                        )
                    }
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("start-queue-toolbar")
                    .help("Add all prepared videos to the FIFO queue")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentInputImporter()
                } label: {
                    Label("Add Videos…", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.canReplaceInput)
                .accessibilityIdentifier("choose-video-toolbar")
                .help("Add one or more MOV or MP4 videos (Command-O)")
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: importTarget == .input
        ) { result in
            handleSelection(result)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canReplaceInput, !urls.isEmpty else { return false }
            Task { await model.importVideos(urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resizer")
                    .font(.title2.weight(.semibold))
                Text("Create smaller, compatible MP4 copies in order.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Local processing", systemImage: "lock.shield")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("Videos are processed locally on this Mac")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var queueSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queue")
                        .font(.headline)
                    Text("\(model.jobs.count) videos this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding videos")
                }
            }
            .padding(14)

            Divider()

            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "No videos",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add MOV or MP4 files to begin.")
                )
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("empty-queue")
            } else {
                List(selection: selectionBinding) {
                    ForEach(model.jobs) { job in
                        queueRow(job)
                            .tag(job.id)
                            .accessibilityIdentifier(
                                "queue-row-\(job.id.uuidString)"
                            )
                    }
                }
                .accessibilityIdentifier("job-queue")
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    guard let jobID = model.selectedJobID,
                          let index = model.snapshot.queuedJobIDs.firstIndex(
                            of: jobID
                          ),
                          index > 0 else {
                        return
                    }
                    let successor = model.snapshot.queuedJobIDs[index - 1]
                    Task {
                        await model.moveQueued(
                            jobID: jobID,
                            before: successor
                        )
                    }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!model.canMoveSelectedUp)
                .accessibilityLabel("Move selected job up")
                .accessibilityIdentifier("move-queue-job-up")

                Button {
                    guard let jobID = model.selectedJobID,
                          let index = model.snapshot.queuedJobIDs.firstIndex(
                            of: jobID
                          ),
                          index + 1 < model.snapshot.queuedJobIDs.count else {
                        return
                    }
                    let successorIndex = index + 2
                    let successor = successorIndex
                        < model.snapshot.queuedJobIDs.count
                        ? model.snapshot.queuedJobIDs[successorIndex]
                        : nil
                    Task {
                        await model.moveQueued(
                            jobID: jobID,
                            before: successor
                        )
                    }
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(!model.canMoveSelectedDown)
                .accessibilityLabel("Move selected job down")
                .accessibilityIdentifier("move-queue-job-down")

                Button(role: .destructive) {
                    guard let jobID = model.selectedJobID else { return }
                    Task { await model.removeQueued(jobID: jobID) }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!model.canRemoveSelected)
                .accessibilityLabel("Remove selected waiting job")
                .accessibilityIdentifier("remove-queue-job")

                Spacer()

                if let selectedJobID = model.selectedJobID,
                   model.canCancel(jobID: selectedJobID) {
                    Button("Cancel") {
                        Task { await model.cancel(jobID: selectedJobID) }
                    }
                    .accessibilityIdentifier("cancel-selected-job")
                } else if let selectedJobID = model.selectedJobID,
                          model.canRetry(jobID: selectedJobID) {
                    Button("Retry") {
                        Task {
                            await model.retry(
                                jobID: selectedJobID,
                                filenameSuffix: validatedFilenameSuffix,
                                conflictPolicy: conflictPolicy
                            )
                        }
                    }
                    .accessibilityIdentifier("retry-selected-job")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Text("The queue is kept only while Resizer is open.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func queueRow(_ job: CompressionJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: queueSymbol(for: job))
                .foregroundStyle(queueTint(for: job))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.inputURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(queueStatus(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .running(let progress?) = job.state,
                   let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(job.inputURL.lastPathComponent), \(queueStatus(for: job))"
        )
    }

    @ViewBuilder
    private var screenContent: some View {
        switch model.screenState {
        case .empty:
            emptyState
        case .importing:
            activityCard(
                title: "Adding videos…",
                detail: "Acquiring secure access and preparing queue items."
            )
        case .probing(let job):
            VStack(spacing: 20) {
                sourceCard(job)
                activityCard(
                    title: "Reading video details…",
                    detail: "Checking duration, streams, codecs, and dimensions.",
                    cancellableJobID: job.id
                )
            }
        case .ready(let job):
            readyView(job)
        case .queued(let job, let position):
            queuedView(job, position: position)
        case .running(let job, let stage):
            runningView(job, stage: stage)
        case .cancelling(let job, let progress):
            cancellingView(job, progress: progress)
        case .success(let job, let result):
            successView(job, result: result)
        case .failure(let job, let failure):
            failureView(job, presentation: failure)
        case .validationError(let message):
            validationErrorView(message)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 7) {
                Text("Drop videos here")
                    .font(.title2.weight(.semibold))
                Text("MOV and MP4 are supported")
                    .foregroundStyle(.secondary)
            }

            Button("Add Videos…") {
                presentInputImporter()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("choose-video")

            Label(
                "The original is never changed. Your video stays on this Mac.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drop-zone")
        .accessibilityLabel("Video queue drop zone")
        .accessibilityHint("Drop MOV or MP4 videos, or use Add Videos")
    }

    private func readyView(_ job: CompressionJob) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)
            settingsCard
            outputCard

            HStack {
                Text(
                    model.readyJobs.count == 1
                        ? "A unique temporary file is validated before the final copy appears."
                        : "All \(model.readyJobs.count) prepared videos will capture these settings."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    model.readyJobs.count == 1
                        ? "Start Compression"
                        : "Start \(model.readyJobs.count) Videos"
                ) {
                    Task {
                        await model.start(
                            filenameSuffix: validatedFilenameSuffix,
                            conflictPolicy: conflictPolicy
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
                .accessibilityIdentifier("start-compression")
            }
        }
    }

    private func queuedView(
        _ job: CompressionJob,
        position: Int
    ) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Waiting in queue", systemImage: "clock")
                        .font(.title3.weight(.semibold))
                    Text("Position \(position). Jobs are processed one at a time in FIFO order.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("This job already captured its compression and output settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            Task { await model.cancel(jobID: job.id) }
                        }
                        .disabled(!model.canCancel(jobID: job.id))
                        .accessibilityIdentifier("cancel-queued-job")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var settingsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Preset", selection: presetBinding) {
                    ForEach(CompressionPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.title).tag(Optional(preset))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("preset-picker")

                if model.draftSettings.selectedPreset == nil {
                    Text("Custom settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("custom-settings-status")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Smaller file")
                        Spacer()
                        Text("Better quality")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Slider(value: qualityBinding, in: 0 ... 1)
                        .accessibilityLabel("Video quality")
                        .accessibilityValue(
                            model.draftSettings.quality.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                        )
                        .accessibilityIdentifier("quality-slider")
                }

                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text(recipeSummary)
                        .font(.callout)
                }

                DisclosureGroup(
                    "Advanced Settings",
                    isExpanded: $isAdvancedSettingsExpanded
                ) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                        GridRow {
                            Text("Maximum resolution")
                            Picker("Maximum resolution", selection: resolutionBinding) {
                                ForEach(
                                    Array(
                                        CompressionDraftSettings.ResolutionOption
                                            .allCases.enumerated()
                                    ),
                                    id: \.offset
                                ) { _, option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("resolution-picker")
                        }

                        GridRow {
                            Text("Frame rate")
                            Picker("Frame rate", selection: frameRateBinding) {
                                ForEach(
                                    Array(
                                        CompressionDraftSettings.FrameRateOption
                                            .allCases.enumerated()
                                    ),
                                    id: \.offset
                                ) { _, option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("frame-rate-picker")
                        }

                        GridRow {
                            Text("Audio")
                            Picker("Audio", selection: audioBinding) {
                                ForEach(
                                    Array(
                                        CompressionDraftSettings.AudioOption
                                            .allCases.enumerated()
                                    ),
                                    id: \.offset
                                ) { _, option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("audio-picker")
                        }

                        GridRow {
                            Text("Metadata")
                            Picker("Metadata", selection: metadataBinding) {
                                ForEach(
                                    Array(
                                        CompressionDraftSettings.MetadataOption
                                            .allCases.enumerated()
                                    ),
                                    id: \.offset
                                ) { _, option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("metadata-picker")
                        }
                    }
                    .padding(.top, 12)
                }
                .accessibilityIdentifier("advanced-settings")
            }
            .padding(.vertical, 4)
        } label: {
            Label("Compression", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var outputCard: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    if let outputURL = model.outputDirectoryURL {
                        Text(outputURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Output: source name\(validatedFilenameSuffix).mp4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose where to save the compressed copy")
                        Text("The source folder is not assumed in the sandbox.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(model.outputDirectoryURL == nil ? "Choose Folder…" : "Change…") {
                    importTarget = .outputDirectory
                    isImporterPresented = true
                }
                .accessibilityIdentifier("choose-output-folder")
            }
            .padding(.vertical, 4)
        } label: {
            Text("Output Folder")
                .font(.headline)
        }
    }

    private func runningView(
        _ job: CompressionJob,
        stage: CompressionRunningStage
    ) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(stage.title, systemImage: stage.symbolName)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        if case .encoding(let progress?) = stage,
                           let fraction = progress.fractionCompleted {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    progressView(for: stage)

                    if case .encoding(let progress?) = stage {
                        HStack(spacing: 20) {
                            if let speed = progress.speed, speed > 0 {
                                Label(
                                    "\(speed.formatted(.number.precision(.fractionLength(1))))×",
                                    systemImage: "speedometer"
                                )
                            }
                            if let eta = model.estimatedRemainingSeconds {
                                Label(
                                    "About \(Self.durationString(seconds: eta)) remaining",
                                    systemImage: "clock"
                                )
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("The original remains untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            Task { await model.cancel(jobID: job.id) }
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canCancel(jobID: job.id))
                        .accessibilityIdentifier("cancel-compression")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func cancellingView(
        _ job: CompressionJob,
        progress: TranscodeProgress?
    ) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cancelling…")
                                .font(.headline)
                            Text("Waiting for the encoder and its output pipes to close safely.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let fraction = progress?.fractionCompleted {
                        ProgressView(value: fraction)
                            .accessibilityIdentifier("compression-progress")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func successView(
        _ job: CompressionJob,
        result: CompressionResult
    ) -> some View {
        let inputBytes = job.mediaInfo?.byteCount ?? 0

        return VStack(spacing: 20) {
            GroupBox {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)

                    VStack(spacing: 5) {
                        Text("Compressed copy is ready")
                            .font(.title2.weight(.semibold))
                        Text(result.outputURL.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 28) {
                            resultMetric("Before", value: Self.byteCountString(inputBytes))
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            resultMetric("After", value: Self.byteCountString(result.outputByteCount))
                            if let savings = Self.savings(input: inputBytes, output: result.outputByteCount) {
                                resultMetric("Saved", value: savings)
                            }
                            resultMetric("Time", value: Self.durationString(result.elapsed))
                        }

                        VStack(spacing: 12) {
                            resultMetric(
                                "Size",
                                value: "\(Self.byteCountString(inputBytes)) → \(Self.byteCountString(result.outputByteCount))"
                            )
                            if let savings = Self.savings(input: inputBytes, output: result.outputByteCount) {
                                resultMetric("Saved", value: savings)
                            }
                            resultMetric("Time", value: Self.durationString(result.elapsed))
                        }
                    }

                    HStack {
                        Button("Add More Videos…") {
                            presentInputImporter()
                        }
                        .accessibilityIdentifier("choose-another-video")

                        Spacer()

                        Button("Reveal in Finder") {
                            model.revealResultInFinder(jobID: job.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reveal-output")
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func failureView(
        _ job: CompressionJob,
        presentation: CompressionFailurePresentation
    ) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)

            if job.mediaInfo != nil {
                settingsCard
                outputCard
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: presentation.symbolName)
                            .font(.title2)
                            .foregroundStyle(presentation.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.title)
                                .font(.title3.weight(.semibold))
                            Text(presentation.detail)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.diagnosticText(for: job.id) != nil {
                        diagnosticDisclosure(jobID: job.id)
                    }

                    HStack {
                        Button("Add More Videos…") {
                            presentInputImporter()
                        }
                        .disabled(!model.canReplaceInput)

                        Spacer()

                        Button("Retry") {
                            Task {
                                await model.retry(
                                    jobID: job.id,
                                    filenameSuffix: validatedFilenameSuffix,
                                    conflictPolicy: conflictPolicy
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRetry(jobID: job.id))
                        .accessibilityIdentifier("retry-compression")
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func diagnosticDisclosure(
        jobID: CompressionJob.ID
    ) -> some View {
        DisclosureGroup("Diagnostics", isExpanded: $isDiagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Resizer · FFmpeg \(CompressionPreferences.bundledFFmpegVersion) · LGPL-only")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let text = model.diagnosticText(for: jobID) {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("Only the bounded tail of the encoder diagnostic is shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Diagnostics") {
                            model.copyDiagnostics(jobID: jobID)
                        }
                        .accessibilityIdentifier("copy-diagnostics")
                    }
                }
            }
            .padding(.top, 10)
        }
        .accessibilityIdentifier("diagnostics")
    }

    private func validationErrorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Check your selection")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack {
                Button("Back") {
                    model.dismissValidationError()
                }
                Button("Add Videos…") {
                    presentInputImporter()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canReplaceInput)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .accessibilityIdentifier("validation-error")
    }

    private func sourceCard(_ job: CompressionJob) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "film.stack")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 8) {
                    Text(job.inputURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Source video \(job.inputURL.lastPathComponent)")

                    if let mediaInfo = job.mediaInfo {
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 130), alignment: .leading),
                            ],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            metadataValue("Size", Self.byteCountString(mediaInfo.byteCount))
                            metadataValue("Duration", Self.mediaDurationString(mediaInfo.durationMicroseconds))
                            metadataValue("Resolution", Self.resolutionString(mediaInfo))
                            metadataValue("Frame rate", Self.frameRateString(mediaInfo))
                            metadataValue("Codecs", Self.codecString(mediaInfo))
                        }
                    } else {
                        Text("Waiting for metadata…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Text("Source")
                .font(.headline)
        }
        .accessibilityIdentifier("source-card")
    }

    private func activityCard(
        title: String,
        detail: String,
        cancellableJobID: CompressionJob.ID? = nil
    ) -> some View {
        GroupBox {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cancellableJobID,
                   model.canCancel(jobID: cancellableJobID) {
                    Button("Cancel") {
                        Task {
                            await model.cancel(jobID: cancellableJobID)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-compression")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("workflow-activity")
    }

    @ViewBuilder
    private func progressView(for stage: CompressionRunningStage) -> some View {
        if case .encoding(let progress?) = stage,
           let fraction = progress.fractionCompleted {
            ProgressView(value: fraction)
                .accessibilityValue(
                    fraction.formatted(.percent.precision(.fractionLength(0)))
                )
                .accessibilityIdentifier("compression-progress")
        } else {
            ProgressView()
                .accessibilityIdentifier("compression-progress")
        }
    }

    private func metadataValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
        }
    }

    private func resultMetric(_ label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionBinding: Binding<CompressionJob.ID?> {
        Binding(
            get: { model.selectedJobID },
            set: { model.selectJob($0) }
        )
    }

    private func validationBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
            Spacer()
            Button("Dismiss") {
                model.dismissValidationError()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .accessibilityIdentifier("queue-validation-banner")
    }

    private func queueStatus(for job: CompressionJob) -> String {
        switch job.state {
        case .draft:
            "Waiting to inspect"
        case .probing:
            "Reading details"
        case .ready:
            "Ready"
        case .queued where model.snapshot.activeJobID == job.id:
            "Preparing"
        case .queued:
            if let position = model.queuePosition(for: job.id) {
                "Waiting · #\(position)"
            } else {
                "Waiting"
            }
        case .running(let progress):
            if let fraction = progress?.fractionCompleted {
                "Compressing · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
            } else {
                "Compressing"
            }
        case .finishing(.validating):
            "Validating"
        case .finishing(.committing):
            "Saving"
        case .cancelling:
            "Cancelling"
        case .cancelled:
            "Cancelled"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        }
    }

    private func queueSymbol(for job: CompressionJob) -> String {
        switch job.state {
        case .draft, .probing:
            "magnifyingglass"
        case .ready:
            "checkmark.circle"
        case .queued:
            "clock"
        case .running:
            "film"
        case .finishing:
            "checkmark.shield"
        case .cancelling, .cancelled:
            "xmark.circle"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func queueTint(for job: CompressionJob) -> Color {
        switch job.state {
        case .running, .finishing:
            .accentColor
        case .completed:
            .green
        case .failed:
            .red
        case .cancelling, .cancelled:
            .secondary
        case .draft, .probing, .ready, .queued:
            .secondary
        }
    }

    private var presetBinding: Binding<CompressionPreset?> {
        Binding(
            get: { model.draftSettings.selectedPreset },
            set: { preset in
                if let preset { model.applyPreset(preset) }
            }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { model.draftSettings.quality },
            set: { model.setQuality($0) }
        )
    }

    private var resolutionBinding: Binding<CompressionDraftSettings.ResolutionOption> {
        Binding(
            get: { model.draftSettings.resolution },
            set: { model.setResolution($0) }
        )
    }

    private var frameRateBinding: Binding<CompressionDraftSettings.FrameRateOption> {
        Binding(
            get: { model.draftSettings.frameRate },
            set: { model.setFrameRate($0) }
        )
    }

    private var audioBinding: Binding<CompressionDraftSettings.AudioOption> {
        Binding(
            get: { model.draftSettings.audio },
            set: { model.setAudio($0) }
        )
    }

    private var metadataBinding: Binding<CompressionDraftSettings.MetadataOption> {
        Binding(
            get: { model.draftSettings.metadata },
            set: { model.setMetadata($0) }
        )
    }

    private var recipeSummary: String {
        let settings = model.draftSettings
        return [
            "MP4", "H.264", settings.resolution.summary,
            settings.frameRate.summary, settings.audio.summary,
        ].joined(separator: " · ")
    }

    private var validatedFilenameSuffix: String {
        guard case let .valid(normalizedValue) =
                CompressionPreferences.validateOutputFilenameSuffix(filenameSuffix) else {
            return CompressionPreferences.defaultOutputFilenameSuffix
        }
        return normalizedValue
    }

    private var conflictPolicy: OutputConflictPolicy {
        (OutputConflictPreference(rawValue: conflictPolicyRawValue)
            ?? CompressionPreferences.defaultOutputConflictPolicy).domainValue
    }

    private func presentInputImporter() {
        importTarget = .input
        isImporterPresented = true
    }

    private func handleSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            switch importTarget {
            case .input:
                guard !urls.isEmpty else { return }
                Task { await model.importVideos(urls) }
            case .outputDirectory:
                guard let url = urls.first else { return }
                model.selectOutputDirectory(url)
            }
        case .failure(let error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain
                    && cocoaError.code == NSUserCancelledError) else {
                return
            }
            switch importTarget {
            case .input:
                model.reportInputSelectionError()
            case .outputDirectory:
                model.reportOutputDirectorySelectionError()
            }
        }
    }
}

private extension CompressionPreset {
    var title: String {
        switch self {
        case .highQuality: "Best Quality"
        case .balanced: "Balanced"
        case .smallFile: "Smaller File"
        }
    }
}

private extension CompressionDraftSettings.ResolutionOption {
    var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "Up to 2160p"
        case .p1080: "Up to 1080p"
        case .p720: "Up to 720p"
        case .p480: "Up to 480p"
        }
    }

    var summary: String { title.lowercased() }
}

private extension CompressionDraftSettings.FrameRateOption {
    var title: String {
        switch self {
        case .original: "Original"
        case .fps60: "Up to 60 fps"
        case .fps30: "Up to 30 fps"
        case .fps24: "Up to 24 fps"
        }
    }

    var summary: String {
        switch self {
        case .original: "original FPS"
        case .fps60: "up to 60 FPS"
        case .fps30: "up to 30 FPS"
        case .fps24: "up to 24 FPS"
        }
    }
}

private extension CompressionDraftSettings.AudioOption {
    var title: String {
        switch self {
        case .aac192Kbps: "AAC 192 kbps"
        case .aac128Kbps: "AAC 128 kbps"
        case .aac96Kbps: "AAC 96 kbps"
        case .remove: "No audio"
        }
    }

    var summary: String {
        switch self {
        case .remove: "no audio"
        case .aac192Kbps, .aac128Kbps, .aac96Kbps: "AAC"
        }
    }
}

private extension CompressionDraftSettings.MetadataOption {
    var title: String {
        switch self {
        case .preserve: "Preserve common metadata"
        case .remove: "Remove metadata"
        }
    }
}

private extension CompressionRunningStage {
    var title: String {
        switch self {
        case .preparing: "Preparing compression…"
        case .encoding: "Compressing video…"
        case .validating: "Validating compressed copy…"
        case .committing: "Saving final copy…"
        }
    }

    var symbolName: String {
        switch self {
        case .preparing: "gearshape.2"
        case .encoding: "film"
        case .validating: "checkmark.shield"
        case .committing: "square.and.arrow.down"
        }
    }
}

private extension CompressionFailurePresentation {
    var title: String {
        switch self {
        case .cancelled:
            "Compression cancelled"
        case .transcode(let failure):
            switch failure.stage {
            case .probe: "Couldn’t read this video"
            case .preflight: "Couldn’t prepare compression"
            case .encode: "Compression failed"
            case .validate: "Couldn’t validate the compressed copy"
            case .commit: "Couldn’t save the compressed copy"
            }
        }
    }

    var detail: String {
        switch self {
        case .cancelled:
            "No final output was published. You can safely retry."
        case .transcode(let failure):
            switch failure.reason {
            case .serviceUnavailable:
                "The bundled video tools or required encoder are unavailable."
            case .invalidMedia:
                "The selected video contains media this version cannot process."
            case .processFailed(let exitCode):
                if let exitCode {
                    "The bundled encoder exited with status \(exitCode)."
                } else {
                    "The bundled encoder stopped unexpectedly."
                }
            case .fileSystem:
                "Check that the selected file and output folder are still available."
            case .unknown:
                "The operation stopped unexpectedly. Diagnostics may contain more detail."
            }
        }
    }

    var symbolName: String {
        switch self {
        case .cancelled: "xmark.circle"
        case .transcode: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .cancelled: .secondary
        case .transcode: .red
        }
    }
}

private extension ContentView {
    static func byteCountString(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func mediaDurationString(_ microseconds: Int64?) -> String {
        guard let microseconds else { return "Unknown" }
        return durationString(seconds: Double(microseconds) / 1_000_000)
    }

    static func durationString(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return durationString(seconds: seconds)
    }

    static func durationString(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        let rounded = Int(seconds.rounded())
        let hours = rounded / 3_600
        let minutes = (rounded % 3_600) / 60
        let remainingSeconds = rounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func resolutionString(_ mediaInfo: MediaInfo) -> String {
        guard let video = primaryVideo(in: mediaInfo),
              let encodedWidth = video.encodedWidth,
              let encodedHeight = video.encodedHeight else {
            return "Unknown"
        }
        let rotation = abs(video.rotationDegrees ?? 0) % 180
        let width = rotation == 90 ? encodedHeight : encodedWidth
        let height = rotation == 90 ? encodedWidth : encodedHeight
        return "\(width) × \(height)"
    }

    static func frameRateString(_ mediaInfo: MediaInfo) -> String {
        guard let value = primaryVideo(in: mediaInfo)?.frameRate?.doubleValue else {
            return "Unknown"
        }
        return "\(value.formatted(.number.precision(.fractionLength(0 ... 2)))) fps"
    }

    static func codecString(_ mediaInfo: MediaInfo) -> String {
        let video = primaryVideo(in: mediaInfo)?.codecName?.uppercased() ?? "Unknown video"
        let audio = mediaInfo.audioStreams.first?.codecName?.uppercased()
        return audio.map { "\(video) / \($0)" } ?? "\(video) / No audio"
    }

    static func savings(input: Int64, output: Int64) -> String? {
        guard input > 0, output >= 0, output < input else { return nil }
        let fraction = 1 - (Double(output) / Double(input))
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func primaryVideo(in mediaInfo: MediaInfo) -> VideoStreamInfo? {
        mediaInfo.videoStreams.first { !$0.disposition.isAttachedPicture }
    }
}

#if DEBUG
#Preview("Empty") {
    if let composition = try? AppComposition.preview() {
        ContentView(model: composition.compressionFeatureModel)
    } else {
        Text("Preview unavailable")
    }
}

#Preview("Queue Ready") {
    if let composition = try? AppComposition.preview() {
        ContentView(model: composition.compressionFeatureModel)
            .task {
                let model = composition.compressionFeatureModel
                guard model.currentJob == nil else { return }
                await model.importVideos([
                    URL(fileURLWithPath: "/tmp/Screen Recording.mov"),
                    URL(fileURLWithPath: "/tmp/Interview.mp4"),
                    URL(fileURLWithPath: "/tmp/Product Demo.mov"),
                ])
                model.selectOutputDirectory(
                    URL(fileURLWithPath: "/tmp", isDirectory: true)
                )
            }
    } else {
        Text("Preview unavailable")
    }
}
#endif
