import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CompressionFrameRateSummary: Sendable, Equatable {
    case source(Double)
    case maximum(Double)
    case originalUnknown
}

nonisolated enum CompressionSummaryFormatter {
    private static let frameRateComparisonTolerance = 0.01

    static func frameRateSummary(
        policy: FrameRatePolicy,
        sourceFramesPerSecond: Double?
    ) -> CompressionFrameRateSummary {
        let sourceFramesPerSecond = sourceFramesPerSecond.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }

        switch policy {
        case .original:
            if let sourceFramesPerSecond {
                return .source(sourceFramesPerSecond)
            }
            return .originalUnknown
        case .capped(let limit):
            if let sourceFramesPerSecond,
               sourceFramesPerSecond
                    <= limit.framesPerSecond + frameRateComparisonTolerance {
                return .source(sourceFramesPerSecond)
            }
            return .maximum(limit.framesPerSecond)
        }
    }

    static func videoCodecSummary(
        outputPixelFormat: OutputPixelFormat
    ) -> String {
        switch outputPixelFormat {
        case .yuv420p:
            "H.264"
        case .yuv420p10le:
            "H.264 10-bit 4:2:0"
        case .yuv422p10le:
            "H.264 10-bit 4:2:2"
        case .yuv444p10le:
            "H.264 10-bit 4:4:4"
        }
    }
}

struct ContentView: View {
    private enum AccessibilityFocusTarget: Hashable {
        case validationError
        case validationBanner
        case failure
        case success
        case noBenefit
    }

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
    @State private var isDiagnosticsExpanded = false
    @AccessibilityFocusState private var accessibilityFocus:
        AccessibilityFocusTarget?

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
                            "Start \(model.startableReadyJobCount)",
                            systemImage: "play.fill"
                        )
                    }
                    .disabled(!model.canStart)
                    .accessibilityIdentifier("start-queue-toolbar")
                    .help("Add all prepared videos to the FIFO queue")
                    .keyboardShortcut(.return, modifiers: [.command])
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
        .onChange(of: model.screenState) { _, state in
            switch state {
            case .validationError:
                accessibilityFocus = .validationError
            case .failure:
                accessibilityFocus = .failure
            case .success:
                accessibilityFocus = .success
            case .noBenefit:
                accessibilityFocus = .noBenefit
            case .empty, .importing, .probing, .ready, .queued,
                 .running, .cancelling:
                break
            }
        }
        .onChange(of: model.validationMessage) { _, message in
            if message != nil, !model.jobs.isEmpty {
                accessibilityFocus = .validationBanner
            }
        }
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
                .keyboardShortcut(
                    .upArrow,
                    modifiers: [.command, .option]
                )
                .help("Move selected job up (Option-Command-Up Arrow)")

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
                .keyboardShortcut(
                    .downArrow,
                    modifiers: [.command, .option]
                )
                .help("Move selected job down (Option-Command-Down Arrow)")

                Button(role: .destructive) {
                    guard let jobID = model.selectedJobID else { return }
                    Task { await model.removeJob(jobID: jobID) }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!model.canRemoveSelected)
                .accessibilityLabel("Remove selected video from the queue")
                .accessibilityIdentifier("remove-queue-job")
                .keyboardShortcut(.delete, modifiers: [])
                .help("Remove selected video from this session (Delete)")

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
                title: String(localized: "Adding videos…"),
                detail: String(
                    localized: "Acquiring secure access and preparing queue items."
                )
            )
        case .probing(let job):
            VStack(spacing: 20) {
                sourceCard(job)
                activityCard(
                    title: String(localized: "Reading video details…"),
                    detail: String(
                        localized: "Checking duration, streams, codecs, and dimensions."
                    ),
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
        case .noBenefit(let job, let result):
            noBenefitView(job, result: result)
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
                .accessibilityHidden(true)

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
            settingsCard(job)
            outputCard(job)

            HStack {
                Text(
                    model.startableReadyJobCount == 1
                        ? "A unique temporary file is validated before the final copy appears."
                        : "Each prepared video keeps its own compression settings."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    model.startableReadyJobCount == 1
                        ? "Start Compression"
                        : "Start \(model.startableReadyJobCount) Videos"
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

    private func settingsCard(_ job: CompressionJob) -> some View {
        GroupBox {
            if model.canEditCompression(jobID: job.id) {
                editableCompressionSettings(job)
            } else {
                capturedCompressionSettings(job)
            }
        } label: {
            Text("Compression")
                .font(.headline)
        }
        .accessibilityIdentifier("compression-settings")
    }

    private func editableCompressionSettings(
        _ job: CompressionJob
    ) -> some View {
        let draft = model.compressionDraft(for: job.id)

        return VStack(alignment: .leading, spacing: 14) {
            Picker(
                "Compression mode",
                selection: compressionModeBinding(for: job.id)
            ) {
                Label("Quick", systemImage: "bolt.fill")
                    .tag(CompressionControlMode.quick)
                Label("Flexible", systemImage: "slider.horizontal.3")
                    .tag(CompressionControlMode.flexible)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .accessibilityIdentifier("compression-mode-selector")

            Divider()

            switch draft.controlMode {
            case .quick:
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ready with balanced settings")
                                .font(.headline)
                            Text(draftRecipeSummary(for: job))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                    }

                    audioToggle(for: job)
                }
                .accessibilityIdentifier("quick-compression-settings")

            case .flexible:
                flexibleCompressionSettings(job, draft: draft)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flexibleCompressionSettings(
        _ job: CompressionJob,
        draft: CompressionDraftSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Quality") {
                HStack(spacing: 10) {
                    Slider(
                        value: qualityBinding(for: job.id),
                        in: FlexibleCompressionSettings.minimumQuality ...
                            FlexibleCompressionSettings.maximumQuality,
                        step: 0.05
                    )
                    .frame(minWidth: 220)
                    .accessibilityIdentifier("flexible-quality")

                    Text("\(Int((draft.quality * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            HStack {
                Text("Smaller file")
                Spacer()
                Text("Higher quality")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 125)

            LabeledContent("Resolution") {
                Picker(
                    "Resolution",
                    selection: resolutionBinding(for: job.id)
                ) {
                    ForEach(FlexibleResolution.allCases, id: \.self) {
                        Text(resolutionTitle($0)).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .accessibilityIdentifier("flexible-resolution")
            }

            LabeledContent("Frame Rate") {
                Picker(
                    "Frame Rate",
                    selection: frameRateBinding(for: job.id)
                ) {
                    ForEach(FlexibleFrameRate.allCases, id: \.self) {
                        Text(frameRateTitle($0)).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .accessibilityIdentifier("flexible-frame-rate")
            }

            audioToggle(for: job)

            Text(draftRecipeSummary(for: job))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("flexible-compression-summary")
        }
        .accessibilityIdentifier("flexible-compression-settings")
    }

    private func audioToggle(for job: CompressionJob) -> some View {
        let hasAudio = job.mediaInfo?.audioStreams.isEmpty == false
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(
                "Keep Audio",
                isOn: keepsAudioBinding(for: job)
            )
            .toggleStyle(.switch)
            .disabled(!hasAudio)
            .accessibilityIdentifier("keep-audio")

            if !hasAudio {
                Text("This video has no audio track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capturedCompressionSettings(
        _ job: CompressionJob
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: capturedCompressionSymbol(for: job))
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(capturedCompressionTitle(for: job))
                    .font(.headline)
                Text(recipeSummary(for: job))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("compression-summary")
                Text(capturedCompressionDetail(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outputCard(_ job: CompressionJob) -> some View {
        return GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

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
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .accessibilityLabel(
                    model.outputDirectoryURL == nil
                        ? "Choose output folder"
                        : "Change output folder"
                )
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
                        .accessibilityElement(children: .combine)
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
                            .accessibilityLabel("Cancelling compression")
                            .accessibilityValue(
                                fraction.formatted(
                                    .percent.precision(.fractionLength(0))
                                )
                            )
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
        let inputBytes = result.sourceByteCount

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
                            .accessibilityFocused(
                                $accessibilityFocus,
                                equals: .success
                            )
                            .accessibilityAddTraits(.isHeader)
                        Text(result.outputURL.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 28) {
                            resultMetric(
                                String(localized: "Before"),
                                value: Self.byteCountString(inputBytes)
                            )
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            resultMetric(
                                String(localized: "After"),
                                value: Self.byteCountString(result.outputByteCount)
                            )
                            if let savings = Self.savings(input: inputBytes, output: result.outputByteCount) {
                                resultMetric(String(localized: "Saved"), value: savings)
                            }
                            resultMetric(
                                String(localized: "Time"),
                                value: Self.durationString(result.elapsed)
                            )
                        }

                        VStack(spacing: 12) {
                            resultMetric(
                                String(localized: "Size"),
                                value: "\(Self.byteCountString(inputBytes)) → \(Self.byteCountString(result.outputByteCount))"
                            )
                            if let savings = Self.savings(input: inputBytes, output: result.outputByteCount) {
                                resultMetric(String(localized: "Saved"), value: savings)
                            }
                            resultMetric(
                                String(localized: "Time"),
                                value: Self.durationString(result.elapsed)
                            )
                        }
                    }

                    HStack {
                        Button("Add More Videos…") {
                            presentInputImporter()
                        }
                        .accessibilityIdentifier("choose-another-video")

                        Spacer()

                        Button("Open") {
                            Task { await model.openResult(jobID: job.id) }
                        }
                        .accessibilityIdentifier("open-output")

                        Button("Reveal in Finder") {
                            Task {
                                await model.revealResultInFinder(jobID: job.id)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reveal-output")
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func noBenefitView(
        _ job: CompressionJob,
        result: CompressionNoBenefitResult
    ) -> some View {
        VStack(spacing: 20) {
            sourceCard(job)

            GroupBox {
                VStack(spacing: 18) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(spacing: 5) {
                        Text("Quick couldn’t make this video smaller")
                            .font(.title2.weight(.semibold))
                            .accessibilityFocused(
                                $accessibilityFocus,
                                equals: .noBenefit
                            )
                            .accessibilityAddTraits(.isHeader)
                        Text("The Quick result was larger than the original, so no new copy was saved.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 28) {
                        resultMetric(
                            String(localized: "Original"),
                            value: Self.byteCountString(result.sourceByteCount)
                        )
                        resultMetric(
                            String(localized: "Attempted"),
                            value: Self.byteCountString(result.candidateByteCount)
                        )
                        resultMetric(
                            String(localized: "Time"),
                            value: Self.durationString(result.elapsed)
                        )
                    }

                    HStack {
                        Button("Add More Videos…") {
                            presentInputImporter()
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .accessibilityIdentifier("no-benefit-result")
    }

    private func failureView(
        _ job: CompressionJob,
        presentation: CompressionFailurePresentation
    ) -> some View {
        let diagnosticText = model.diagnosticText(for: job.id)

        return VStack(spacing: 20) {
            sourceCard(job)

            if job.mediaInfo != nil {
                settingsCard(job)
                outputCard(job)
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
                                .accessibilityFocused(
                                    $accessibilityFocus,
                                    equals: .failure
                                )
                                .accessibilityAddTraits(.isHeader)
                            Text(presentation.detail)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let diagnosticText {
                        diagnosticDisclosure(
                            diagnosticText,
                            jobID: job.id
                        )
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
                        .keyboardShortcut("r", modifiers: [.command])
                        .help("Retry selected job (Command-R)")
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func diagnosticDisclosure(
        _ diagnosticText: String,
        jobID: CompressionJob.ID
    ) -> some View {
        DisclosureGroup("Diagnostics", isExpanded: $isDiagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Resizer · FFmpeg \(CompressionPreferences.bundledFFmpegVersion) · GPL 2.0+")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(diagnosticText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text(
                        "Technical details include only a bounded, redacted diagnostic tail."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Diagnostics") {
                        model.copyDiagnostics(jobID: jobID)
                    }
                    .accessibilityIdentifier("copy-diagnostics")
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
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .validationError
                )
                .accessibilityAddTraits(.isHeader)
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
                    .accessibilityHidden(true)

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
                            metadataValue(
                                String(localized: "Size"),
                                Self.byteCountString(mediaInfo.byteCount)
                            )
                            metadataValue(
                                String(localized: "Duration"),
                                Self.mediaDurationString(mediaInfo.durationMicroseconds)
                            )
                            metadataValue(
                                String(localized: "Resolution"),
                                Self.resolutionString(mediaInfo)
                            )
                            metadataValue(
                                String(localized: "Frame rate"),
                                Self.frameRateString(mediaInfo)
                            )
                            metadataValue(
                                String(localized: "Codecs"),
                                Self.codecString(mediaInfo)
                            )
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
                .accessibilityLabel(stage.title)
                .accessibilityValue(
                    fraction.formatted(.percent.precision(.fractionLength(0)))
                )
                .accessibilityIdentifier("compression-progress")
        } else {
            ProgressView()
                .accessibilityLabel(stage.title)
                .accessibilityValue("In progress")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
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
                .accessibilityFocused(
                    $accessibilityFocus,
                    equals: .validationBanner
                )
                .accessibilityAddTraits(.isHeader)
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
            String(localized: "Waiting to inspect")
        case .probing:
            String(localized: "Reading details")
        case .ready:
            String(localized: "Ready")
        case .queued where model.snapshot.activeJobID == job.id:
            String(localized: "Preparing")
        case .queued:
            if let position = model.queuePosition(for: job.id) {
                String(localized: "Waiting · #\(position)")
            } else {
                String(localized: "Waiting")
            }
        case .running(let progress):
            if let fraction = progress?.fractionCompleted {
                String(
                    localized: "Compressing · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
                )
            } else {
                String(localized: "Compressing")
            }
        case .finishing(.validating):
            String(localized: "Validating")
        case .finishing(.committing):
            String(localized: "Saving")
        case .cancelling:
            String(localized: "Cancelling")
        case .cancelled:
            String(localized: "Cancelled")
        case .completed:
            String(localized: "Completed")
        case .noBenefit:
            String(localized: "Quick wasn’t smaller")
        case .failed:
            String(localized: "Failed")
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
        case .noBenefit:
            "info.circle.fill"
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
        case .noBenefit:
            .secondary
        case .failed:
            .red
        case .cancelling, .cancelled:
            .secondary
        case .draft, .probing, .ready, .queued:
            .secondary
        }
    }

    private func recipeSummary(for job: CompressionJob) -> String {
        let recipe: CompressionRecipe?
        if let captured = job.configuration?.recipe {
            recipe = captured
        } else if let mediaInfo = job.mediaInfo,
                  let settings = try? model.compressionDraft(
                    for: job.id
                  ).primarySettings() {
            recipe = try? AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: settings
            )
        } else {
            recipe = nil
        }
        guard let recipe else {
            return String(localized: "Compression settings")
        }

        return recipeSummary(recipe, mediaInfo: job.mediaInfo)
    }

    private func draftRecipeSummary(for job: CompressionJob) -> String {
        guard let mediaInfo = job.mediaInfo,
              let settings = try? model.compressionDraft(
                for: job.id
              ).primarySettings(),
              let recipe = try? AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: settings
              ) else {
            return String(localized: "Compression settings")
        }
        return recipeSummary(recipe, mediaInfo: mediaInfo)
    }

    private func recipeSummary(
        _ recipe: CompressionRecipe,
        mediaInfo: MediaInfo?
    ) -> String {
        let resolution = switch recipe.scalePolicy {
        case .original:
            String(localized: "Original resolution")
        case .maximum(let limit):
            String(
                localized: "Up to \(limit.maximumLongEdge)×\(limit.maximumShortEdge)"
            )
        }
        let sourceFramesPerSecond = mediaInfo.flatMap {
            Self.primaryVideo(in: $0)?.frameRate?.doubleValue
        }
        let frameRate = switch CompressionSummaryFormatter.frameRateSummary(
            policy: recipe.frameRatePolicy,
            sourceFramesPerSecond: sourceFramesPerSecond
        ) {
        case .source(let framesPerSecond):
            sourceFrameRateSummary(framesPerSecond)
        case .originalUnknown:
            String(localized: "Original FPS")
        case .maximum(let framesPerSecond):
            String(
                localized: "Up to \(framesPerSecond.formatted(.number)) FPS"
            )
        }
        let audio = switch recipe.audioPolicy {
        case .remove:
            String(localized: "No audio")
        case .aac(let bitRate):
            String(
                localized: "AAC \(bitRate.bitsPerSecond / 1_000) kbps"
            )
        }
        let videoCodec = CompressionSummaryFormatter.videoCodecSummary(
            outputPixelFormat: recipe.outputPixelFormat
        )
        return ["MP4", videoCodec, resolution, frameRate, audio]
            .joined(separator: " · ")
    }

    private func sourceFrameRateSummary(_ framesPerSecond: Double) -> String {
        let formatted = framesPerSecond.formatted(
            .number.precision(.fractionLength(0 ... 2))
        )
        return String(localized: "\(formatted) FPS (same as source)")
    }

    private func capturedCompressionTitle(for job: CompressionJob) -> String {
        switch job.configuration?.recipe.origin {
        case .primary(.quick(audio: _)):
            String(localized: "Quick")
        case .primary(.flexible):
            String(localized: "Flexible")
        case nil:
            String(localized: "Quick")
        }
    }

    private func capturedCompressionSymbol(for job: CompressionJob) -> String {
        switch job.configuration?.recipe.origin {
        case .primary(.flexible):
            "slider.horizontal.3"
        case .primary(.quick):
            "bolt.fill"
        case nil:
            "bolt.fill"
        }
    }

    private func capturedCompressionDetail(for job: CompressionJob) -> String {
        switch job.configuration?.recipe.origin {
        case .primary(.flexible):
            String(localized: "This job captured your flexible settings.")
        case .primary(.quick):
            String(localized: "Quick mode uses a balanced size and quality.")
        case nil:
            String(localized: "Quick mode uses a balanced size and quality.")
        }
    }

    private func compressionModeBinding(
        for jobID: CompressionJob.ID
    ) -> Binding<CompressionControlMode> {
        Binding(
            get: { model.compressionDraft(for: jobID).controlMode },
            set: { model.setCompressionControlMode($0, jobID: jobID) }
        )
    }

    private func qualityBinding(
        for jobID: CompressionJob.ID
    ) -> Binding<Double> {
        Binding(
            get: { model.compressionDraft(for: jobID).quality },
            set: { model.setFlexibleQuality($0, jobID: jobID) }
        )
    }

    private func resolutionBinding(
        for jobID: CompressionJob.ID
    ) -> Binding<FlexibleResolution> {
        Binding(
            get: { model.compressionDraft(for: jobID).resolution },
            set: { model.setFlexibleResolution($0, jobID: jobID) }
        )
    }

    private func frameRateBinding(
        for jobID: CompressionJob.ID
    ) -> Binding<FlexibleFrameRate> {
        Binding(
            get: { model.compressionDraft(for: jobID).frameRate },
            set: { model.setFlexibleFrameRate($0, jobID: jobID) }
        )
    }

    private func keepsAudioBinding(for job: CompressionJob) -> Binding<Bool> {
        Binding(
            get: {
                job.mediaInfo?.audioStreams.isEmpty == false
                    && model.compressionDraft(for: job.id).audioPreference
                        == .keep
            },
            set: { model.setKeepsAudio($0, jobID: job.id) }
        )
    }

    private func resolutionTitle(_ resolution: FlexibleResolution) -> String {
        switch resolution {
        case .source:
            String(localized: "Source")
        case .p1080:
            String(localized: "Up to 1080p")
        case .p720:
            String(localized: "Up to 720p")
        case .p480:
            String(localized: "Up to 480p")
        }
    }

    private func frameRateTitle(_ frameRate: FlexibleFrameRate) -> String {
        switch frameRate {
        case .source:
            String(localized: "Source")
        case .fps60:
            String(localized: "Up to 60 FPS")
        case .fps30:
            String(localized: "Up to 30 FPS")
        case .fps24:
            String(localized: "Up to 24 FPS")
        }
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

private extension CompressionRunningStage {
    var title: String {
        switch self {
        case .preparing: String(localized: "Preparing compression…")
        case .encoding: String(localized: "Compressing video…")
        case .validating:
            String(localized: "Validating compressed copy…")
        case .committing: String(localized: "Saving final copy…")
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
        guard let microseconds else { return String(localized: "Unknown") }
        return durationString(seconds: Double(microseconds) / 1_000_000)
    }

    static func durationString(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return durationString(seconds: seconds)
    }

    static func durationString(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return String(localized: "Unknown")
        }
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
            return String(localized: "Unknown")
        }
        let rotation = abs(video.rotationDegrees ?? 0) % 180
        let width = rotation == 90 ? encodedHeight : encodedWidth
        let height = rotation == 90 ? encodedWidth : encodedHeight
        return "\(width) × \(height)"
    }

    static func frameRateString(_ mediaInfo: MediaInfo) -> String {
        guard let value = primaryVideo(in: mediaInfo)?.frameRate?.doubleValue else {
            return String(localized: "Unknown")
        }
        return String(
            localized: "\(value.formatted(.number.precision(.fractionLength(0 ... 2)))) fps"
        )
    }

    static func codecString(_ mediaInfo: MediaInfo) -> String {
        let video = primaryVideo(in: mediaInfo)?.codecName?.uppercased()
            ?? String(localized: "Unknown video")
        let audio = mediaInfo.audioStreams.first?.codecName?.uppercased()
        return audio.map {
            String(localized: "\(video) / \($0)")
        } ?? String(localized: "\(video) / No audio")
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
