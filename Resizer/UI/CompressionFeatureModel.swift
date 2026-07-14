import AppKit
import Combine
import Foundation

@MainActor
protocol OutputRevealing {
    func reveal(_ outputURL: URL)
}

@MainActor
struct WorkspaceOutputRevealer: OutputRevealing {
    func reveal(_ outputURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }
}

@MainActor
protocol DiagnosticCopying {
    func copyDiagnostic(_ text: String)
}

@MainActor
struct PasteboardDiagnosticCopier: DiagnosticCopying {
    func copyDiagnostic(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class CompressionFeatureModel: ObservableObject {
    @Published private(set) var snapshot: CompressionSnapshot = .empty
    @Published private(set) var currentJobID: CompressionJob.ID?
    @Published private(set) var outputDirectoryURL: URL?
    @Published private(set) var draftSettings = CompressionDraftSettings()
    @Published private(set) var screenState: CompressionViewState = .empty

    private enum Operation {
        case importing
        case workflow
    }

    private enum TransientState {
        case importing
        case validationError(String)
    }

    private let coordinator: any CompressionCoordinating
    private let outputRevealer: any OutputRevealing
    private let diagnosticCopier: any DiagnosticCopying
    private var observationTask: Task<Void, Never>?
    private var operation: Operation? {
        didSet { objectWillChange.send() }
    }
    private var transientState: TransientState?

    private var etaJobID: CompressionJob.ID?
    private var etaSpeedSamples: [Double] = []
    private var etaLastProcessedMicroseconds: Int64?

    init(
        coordinator: any CompressionCoordinating,
        outputRevealer: any OutputRevealing = WorkspaceOutputRevealer(),
        diagnosticCopier: any DiagnosticCopying = PasteboardDiagnosticCopier()
    ) {
        self.coordinator = coordinator
        self.outputRevealer = outputRevealer
        self.diagnosticCopier = diagnosticCopier

        observationTask = Task { [weak self, coordinator] in
            let updates = await coordinator.snapshots()
            for await snapshot in updates {
                guard !Task.isCancelled else { break }
                self?.consume(snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    var jobs: [CompressionJob] {
        snapshot.jobs
    }

    var currentJob: CompressionJob? {
        guard let currentJobID else { return nil }
        return snapshot.jobs.first { $0.id == currentJobID }
    }

    var canStart: Bool {
        guard operation == nil,
              outputDirectoryURL != nil,
              let currentJob,
              case .ready = currentJob.state else {
            return false
        }
        return true
    }

    var canCancel: Bool {
        guard let currentJob else { return false }
        switch currentJob.state {
        case .probing, .queued, .running, .cancelling:
            return true
        case .draft, .ready, .finishing, .cancelled, .completed, .failed:
            return false
        }
    }

    var canRetry: Bool {
        guard operation == nil, let currentJob else { return false }
        switch currentJob.state {
        case .failed(let failure):
            return failure.retryTarget == .probing
                || outputDirectoryURL != nil
        case .cancelled:
            return currentJob.mediaInfo == nil || outputDirectoryURL != nil
        case .draft, .probing, .ready, .queued, .running, .finishing,
             .cancelling, .completed:
            return false
        }
    }

    var canReplaceInput: Bool {
        guard operation == nil, let currentJob else { return true }
        switch currentJob.state {
        case .ready, .cancelled, .completed, .failed:
            return true
        case .draft, .probing, .queued, .running, .finishing,
             .cancelling:
            return false
        }
    }

    var canEditSettings: Bool {
        guard let currentJob else { return true }
        switch currentJob.state {
        case .probing, .queued, .running, .finishing, .cancelling:
            return false
        case .draft, .ready, .cancelled, .completed, .failed:
            return true
        }
    }

    /// ETA is intentionally withheld until three recent speed samples are
    /// positive, the encode has run for at least three seconds, and sample
    /// spread stays within 25 percent.
    var estimatedRemainingSeconds: TimeInterval? {
        guard etaSpeedSamples.count == 3,
              let currentJob,
              case .running(let progress?) = currentJob.state,
              progress.processedMicroseconds >= 3_000_000,
              let total = progress.totalMicroseconds,
              total > progress.processedMicroseconds,
              let minimum = etaSpeedSamples.min(),
              let maximum = etaSpeedSamples.max(),
              minimum > 0,
              maximum <= minimum * 1.25 else {
            return nil
        }

        let average = etaSpeedSamples.reduce(0, +)
            / Double(etaSpeedSamples.count)
        let remaining = Double(total - progress.processedMicroseconds)
            / 1_000_000
            / average
        return remaining.isFinite && remaining >= 0 ? remaining : nil
    }

    /// The domain has already bounded this string; no paths or underlying
    /// error descriptions are synthesized by the presentation layer.
    var diagnosticText: String? {
        guard let currentJob,
              case .failed(let failure) = currentJob.state else {
            return nil
        }
        return failure.diagnosticTail?.text
    }

    /// Low-level registration retained for composition and coordinator tests.
    /// Product import goes through `importVideo(_:)`, which also validates the
    /// extension and performs the separate probe step.
    @discardableResult
    func createJob(inputURL: URL) async throws -> CompressionJob {
        let job = try await coordinator.createJob(
            inputURL: inputURL,
            id: UUID(),
            createdAt: Date()
        )
        currentJobID = job.id
        await synchronizeSnapshot()
        return job
    }

    func importVideo(_ inputURL: URL) async {
        guard operation == nil else { return }
        guard canReplaceInput else {
            presentValidationError(
                "Wait for the current operation to finish before choosing another video."
            )
            return
        }
        guard inputURL.isFileURL,
              Self.supportedInputExtensions.contains(
                  inputURL.pathExtension.lowercased()
              ) else {
            presentValidationError("Choose one MOV or MP4 video.")
            return
        }

        operation = .importing
        transientState = .importing
        recomputeScreenState()
        defer { operation = nil }
        var createdJobID: CompressionJob.ID?

        do {
            if let currentJob, case .ready = currentJob.state {
                await coordinator.cancel(jobID: currentJob.id)
                await synchronizeSnapshot()
                guard self.currentJob?.state == .cancelled else {
                    presentValidationError(
                        "The current video could not be replaced safely."
                    )
                    return
                }
            }

            let job = try await coordinator.createJob(
                inputURL: inputURL,
                id: UUID(),
                createdAt: Date()
            )
            createdJobID = job.id
            currentJobID = job.id
            outputDirectoryURL = nil
            draftSettings = CompressionDraftSettings()
            transientState = nil
            await synchronizeSnapshot()
            _ = try await coordinator.prepare(jobID: job.id)
            await synchronizeSnapshot()
        } catch {
            transientState = nil
            await synchronizeSnapshot()
            if createdJobID == nil
                || currentJob.map(Self.isWorkflowOutcome) != true {
                presentValidationError(
                    "The selected video could not be prepared."
                )
            }
        }
    }

    func reportInputSelectionError() {
        presentValidationError("The video could not be selected.")
    }

    func reportOutputDirectorySelectionError() {
        presentValidationError("The output folder could not be selected.")
    }

    func selectOutputDirectory(_ directoryURL: URL) {
        guard canEditSettings else { return }
        guard directoryURL.isFileURL else {
            presentValidationError("Choose a local output folder.")
            return
        }
        outputDirectoryURL = directoryURL
        dismissValidationError()
    }

    func clearOutputDirectory() {
        guard canEditSettings else { return }
        outputDirectoryURL = nil
    }

    func applyPreset(_ preset: CompressionPreset) {
        guard canEditSettings else { return }
        draftSettings.apply(preset: preset)
        dismissValidationError()
    }

    func setQuality(_ value: Double) {
        guard canEditSettings else { return }
        do {
            try draftSettings.setQuality(value)
            dismissValidationError()
        } catch {
            presentValidationError("Quality must be between 0 and 1.")
        }
    }

    func setResolution(
        _ option: CompressionDraftSettings.ResolutionOption
    ) {
        guard canEditSettings else { return }
        draftSettings.setResolution(option)
        dismissValidationError()
    }

    func setFrameRate(
        _ option: CompressionDraftSettings.FrameRateOption
    ) {
        guard canEditSettings else { return }
        draftSettings.setFrameRate(option)
        dismissValidationError()
    }

    func setAudio(_ option: CompressionDraftSettings.AudioOption) {
        guard canEditSettings else { return }
        draftSettings.setAudio(option)
        dismissValidationError()
    }

    func setMetadata(_ option: CompressionDraftSettings.MetadataOption) {
        guard canEditSettings else { return }
        draftSettings.setMetadata(option)
        dismissValidationError()
    }

    func start(
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) async {
        guard operation == nil,
              let currentJob,
              case .ready = currentJob.state else {
            presentValidationError("Prepare one video before starting.")
            return
        }
        guard let configuration = makeConfiguration(
            filenameSuffix: filenameSuffix,
            conflictPolicy: conflictPolicy
        ) else {
            return
        }

        operation = .workflow
        transientState = nil
        defer { operation = nil }
        do {
            _ = try await coordinator.startPrepared(
                jobID: currentJob.id,
                configuration: configuration
            )
            await synchronizeSnapshot()
        } catch {
            await synchronizeSnapshot()
            if self.currentJob.map(Self.isWorkflowOutcome) != true {
                presentValidationError("Compression could not be started.")
            }
        }
    }

    func cancel() async {
        guard let currentJob, canCancel else { return }
        await coordinator.cancel(jobID: currentJob.id)
        await synchronizeSnapshot()
    }

    func retry(
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) async {
        guard operation == nil, let currentJob else { return }

        let retriesProbe: Bool
        switch currentJob.state {
        case .failed(let failure):
            retriesProbe = failure.retryTarget == .probing
        case .cancelled:
            retriesProbe = currentJob.mediaInfo == nil
        case .draft, .probing, .ready, .queued, .running, .finishing,
             .cancelling, .completed:
            return
        }

        operation = .workflow
        transientState = nil
        defer { operation = nil }
        do {
            if retriesProbe {
                _ = try await coordinator.prepare(jobID: currentJob.id)
            } else {
                guard let configuration = makeConfiguration(
                    filenameSuffix: filenameSuffix,
                    conflictPolicy: conflictPolicy
                ) else {
                    return
                }
                _ = try await coordinator.retry(
                    jobID: currentJob.id,
                    configuration: configuration
                )
            }
            await synchronizeSnapshot()
        } catch {
            await synchronizeSnapshot()
            if self.currentJob.map(Self.isWorkflowOutcome) != true {
                presentValidationError("The operation could not be retried.")
            }
        }
    }

    func revealResultInFinder() {
        guard let currentJob,
              case .completed(let result) = currentJob.state else {
            return
        }
        outputRevealer.reveal(result.outputURL)
    }

    func copyDiagnostics() {
        guard let diagnosticText, !diagnosticText.isEmpty else { return }
        diagnosticCopier.copyDiagnostic(diagnosticText)
    }

    func dismissValidationError() {
        guard case .validationError = transientState else { return }
        transientState = nil
        recomputeScreenState()
    }

    func refresh() async {
        await synchronizeSnapshot()
    }

    private func makeConfiguration(
        filenameSuffix: String,
        conflictPolicy: OutputConflictPolicy
    ) -> JobConfiguration? {
        guard let outputDirectoryURL else {
            presentValidationError("Choose an output folder before starting.")
            return nil
        }

        do {
            return JobConfiguration(
                recipe: try draftSettings.makeRecipe(),
                outputPolicy: try OutputPolicy(
                    directoryURL: outputDirectoryURL,
                    filenameSuffix: filenameSuffix,
                    conflictPolicy: conflictPolicy
                )
            )
        } catch {
            presentValidationError(
                "Check the compression settings and output filename suffix."
            )
            return nil
        }
    }

    private func synchronizeSnapshot() async {
        consume(await coordinator.snapshot())
    }

    private func consume(_ snapshot: CompressionSnapshot) {
        self.snapshot = snapshot
        updateETA(from: currentJob)
        recomputeScreenState()
    }

    private func recomputeScreenState() {
        switch transientState {
        case .importing:
            screenState = .importing
            return
        case .validationError(let message):
            screenState = .validationError(message)
            return
        case nil:
            break
        }

        guard let currentJob else {
            screenState = .empty
            return
        }

        switch currentJob.state {
        case .draft:
            screenState = .importing
        case .probing:
            screenState = .probing(currentJob)
        case .ready:
            screenState = .ready(currentJob)
        case .queued:
            screenState = .running(currentJob, .preparing)
        case .running(let progress):
            screenState = .running(
                currentJob,
                .encoding(progress)
            )
        case .finishing(.validating):
            screenState = .running(currentJob, .validating)
        case .finishing(.committing):
            screenState = .running(currentJob, .committing)
        case .cancelling(let progress):
            screenState = .cancelling(currentJob, progress)
        case .cancelled:
            screenState = .failure(currentJob, .cancelled)
        case .completed(let result):
            screenState = .success(currentJob, result)
        case .failed(let failure):
            screenState = .failure(currentJob, .transcode(failure))
        }
    }

    private func presentValidationError(_ message: String) {
        transientState = .validationError(message)
        recomputeScreenState()
    }

    private func updateETA(from job: CompressionJob?) {
        guard let job,
              case .running(let progress?) = job.state,
              progress.processedMicroseconds >= 3_000_000,
              let speed = progress.speed,
              speed > 0 else {
            resetETA()
            return
        }

        if etaJobID != job.id
            || etaLastProcessedMicroseconds.map({
                progress.processedMicroseconds <= $0
            }) == true {
            etaJobID = job.id
            etaSpeedSamples.removeAll(keepingCapacity: true)
        }

        etaJobID = job.id
        etaLastProcessedMicroseconds = progress.processedMicroseconds
        etaSpeedSamples.append(speed)
        if etaSpeedSamples.count > 3 {
            etaSpeedSamples.removeFirst(
                etaSpeedSamples.count - 3
            )
        }
    }

    private func resetETA() {
        etaJobID = nil
        etaSpeedSamples.removeAll(keepingCapacity: true)
        etaLastProcessedMicroseconds = nil
    }

    private static func isWorkflowOutcome(_ job: CompressionJob) -> Bool {
        switch job.state {
        case .ready, .cancelled, .completed, .failed:
            true
        case .draft, .probing, .queued, .running, .finishing,
             .cancelling:
            false
        }
    }

    private static let supportedInputExtensions: Set<String> = [
        "mov", "mp4",
    ]
}
