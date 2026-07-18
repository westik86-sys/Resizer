import AppKit
import Combine
import Foundation

@MainActor
protocol OutputRevealing {
    func open(
        _ outputURL: URL,
        in outputDirectoryURL: URL
    ) async throws
    func reveal(
        _ outputURLs: [URL],
        in outputDirectoryURLs: [URL]
    ) async throws
}

extension OutputRevealing {
    func reveal(
        _ outputURL: URL,
        in outputDirectoryURL: URL
    ) async throws {
        try await reveal(
            [outputURL],
            in: [outputDirectoryURL]
        )
    }
}

@MainActor
protocol OutputLaunching: Sendable {
    func open(_ outputURL: URL) -> Bool
    func reveal(_ outputURLs: [URL]) -> Bool
}

@MainActor
struct WorkspaceOutputLauncher: OutputLaunching {
    func open(_ outputURL: URL) -> Bool {
        NSWorkspace.shared.open(outputURL)
    }

    func reveal(_ outputURLs: [URL]) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
        return true
    }
}

nonisolated enum OutputRevealError: Error, Sendable, Equatable {
    case openFailed
    case revealFailed
}

@MainActor
struct WorkspaceOutputRevealer: OutputRevealing {
    private let fileAccess: any FileAccessing
    private let launcher: any OutputLaunching

    init(
        fileAccess: any FileAccessing,
        launcher: any OutputLaunching = WorkspaceOutputLauncher()
    ) {
        self.fileAccess = fileAccess
        self.launcher = launcher
    }

    func open(
        _ outputURL: URL,
        in outputDirectoryURL: URL
    ) async throws {
        let launcher = launcher
        let opened = try await fileAccess.withSecurityScopedAccess(
            to: [outputDirectoryURL]
        ) {
            await MainActor.run {
                launcher.open(outputURL)
            }
        }
        guard opened else { throw OutputRevealError.openFailed }
    }

    func reveal(
        _ outputURLs: [URL],
        in outputDirectoryURLs: [URL]
    ) async throws {
        guard !outputURLs.isEmpty else { return }
        let launcher = launcher
        let revealed = try await fileAccess.withSecurityScopedAccess(
            to: outputDirectoryURLs
        ) {
            await MainActor.run {
                guard !currentTaskIsCancelled() else { return false }
                return launcher.reveal(outputURLs)
            }
        }
        guard revealed else { throw OutputRevealError.revealFailed }
    }
}

private nonisolated func currentTaskIsCancelled() -> Bool {
    withUnsafeCurrentTask { task in
        task?.isCancelled ?? false
    }
}

private nonisolated struct PendingFinderReveal: Sendable, Equatable {
    let outputURL: URL
    let outputDirectoryURL: URL
}

private nonisolated struct FinderRevealCompletionKey: Sendable, Hashable {
    let jobID: CompressionJob.ID
    let standardizedOutputPath: String
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

nonisolated struct CompressionDraftSettings: Sendable, Equatable {
    static let defaultQuality = 0.75

    var controlMode: CompressionControlMode = .quick
    var quality = CompressionDraftSettings.defaultQuality
    var resolution: FlexibleResolution = .p1080
    var frameRate: FlexibleFrameRate = .fps30
    var audioPreference: AudioPreference = .keep

    func primarySettings() throws -> PrimaryCompressionSettings {
        switch controlMode {
        case .quick:
            .quick(audio: audioPreference)
        case .flexible:
            .flexible(
                try FlexibleCompressionSettings(
                    quality: VideoQuality(quality),
                    resolution: resolution,
                    frameRate: frameRate,
                    audioPreference: audioPreference
                )
            )
        }
    }
}

@MainActor
final class CompressionFeatureModel: ObservableObject {
    @Published private(set) var snapshot: CompressionSnapshot = .empty
    @Published private(set) var selectedJobID: CompressionJob.ID?
    @Published private(set) var outputDirectoryURL: URL?
    @Published private(set) var screenState: CompressionViewState = .empty
    @Published private(set) var validationMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isStartingQueue = false
    @Published private(set) var pendingActionJobIDs: Set<CompressionJob.ID> = []
    @Published private(set) var compressionDrafts: [
        CompressionJob.ID: CompressionDraftSettings
    ] = [:]

    private let coordinator: any JobQueueCoordinating
    private let outputRevealer: any OutputRevealing
    private let diagnosticCopier: any DiagnosticCopying
    private let automaticallyRevealsCompletedOutputs: () -> Bool
    private var observationTask: Task<Void, Never>?
    private var automaticRevealTask: Task<Void, Never>?
    private var automaticRevealBatches: [[PendingFinderReveal]] = []
    private var pendingImportedSelectionID: CompressionJob.ID?
    private var lastConsumedSnapshotRevision: UInt64?
    private var seenFinderRevealCompletions: Set<
        FinderRevealCompletionKey
    > = []
    private var pendingFinderReveals: [PendingFinderReveal] = []
    private var isShuttingDown = false

    private var etaJobID: CompressionJob.ID?
    private var etaSpeedSamples: [Double] = []
    private var etaLastProcessedMicroseconds: Int64?

    init(
        coordinator: any JobQueueCoordinating,
        outputRevealer: any OutputRevealing = WorkspaceOutputRevealer(
            fileAccess: SecurityScopedFileAccess()
        ),
        diagnosticCopier: any DiagnosticCopying = PasteboardDiagnosticCopier(),
        initialOutputDirectoryURL: URL? = nil,
        automaticallyRevealsCompletedOutputs: @escaping () -> Bool = {
            false
        }
    ) {
        self.coordinator = coordinator
        self.outputRevealer = outputRevealer
        self.diagnosticCopier = diagnosticCopier
        self.outputDirectoryURL = initialOutputDirectoryURL
        self.automaticallyRevealsCompletedOutputs =
            automaticallyRevealsCompletedOutputs

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
        automaticRevealTask?.cancel()
    }

    var jobs: [CompressionJob] {
        snapshot.jobs
    }

    /// Compatibility alias for the completed single-file UI tests. Selection,
    /// rather than workflow ownership, is the Stage 9 meaning of this value.
    var currentJobID: CompressionJob.ID? {
        selectedJobID
    }

    var currentJob: CompressionJob? {
        job(id: selectedJobID)
    }

    var activeJob: CompressionJob? {
        job(id: snapshot.activeJobID)
    }

    var readyJobs: [CompressionJob] {
        jobs.filter { job in
            if case .ready = job.state { return true }
            return false
        }
    }

    private var startableReadyJobs: [CompressionJob] {
        readyJobs.filter { job in
            !pendingActionJobIDs.contains(job.id)
        }
    }

    var startableReadyJobCount: Int {
        startableReadyJobs.count
    }

    var queuedJobs: [CompressionJob] {
        snapshot.queuedJobIDs.compactMap(job(id:))
    }

    var finishedJobs: [CompressionJob] {
        jobs.filter { job in
            switch job.state {
            case .cancelled, .completed, .noBenefit, .failed:
                true
            case .draft, .probing, .ready, .queued, .running,
                 .finishing, .cancelling:
                false
            }
        }
    }

    var canStart: Bool {
        !isImporting
            && !isStartingQueue
            && outputDirectoryURL != nil
            && !startableReadyJobs.isEmpty
    }

    var canCancel: Bool {
        currentJob.map { canCancel(jobID: $0.id) } == true
    }

    var canRetry: Bool {
        currentJob.map { canRetry(jobID: $0.id) } == true
    }

    var canRemoveSelected: Bool {
        currentJob.map { canRemove(jobID: $0.id) } == true
    }

    var canMoveSelectedUp: Bool {
        guard let selectedJobID,
              let index = snapshot.queuedJobIDs.firstIndex(
                of: selectedJobID
              ) else {
            return false
        }
        return index > 0
    }

    var canMoveSelectedDown: Bool {
        guard let selectedJobID,
              let index = snapshot.queuedJobIDs.firstIndex(
                of: selectedJobID
              ) else {
            return false
        }
        return index + 1 < snapshot.queuedJobIDs.count
    }

    var canReplaceInput: Bool {
        !isImporting
    }

    var estimatedRemainingSeconds: TimeInterval? {
        guard etaSpeedSamples.count == 3,
              let activeJob,
              case .running(let progress?) = activeJob.state,
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

    var diagnosticText: String? {
        currentJob.flatMap { diagnosticText(for: $0.id) }
    }

    func job(id: CompressionJob.ID?) -> CompressionJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    func compressionDraft(
        for jobID: CompressionJob.ID
    ) -> CompressionDraftSettings {
        compressionDrafts[jobID] ?? CompressionDraftSettings()
    }

    func canEditCompression(jobID: CompressionJob.ID) -> Bool {
        guard pendingActionJobIDs.contains(jobID) == false,
              let job = job(id: jobID),
              case .ready = job.state else {
            return false
        }
        return true
    }

    func setCompressionControlMode(
        _ mode: CompressionControlMode,
        jobID: CompressionJob.ID
    ) {
        updateCompressionDraft(jobID: jobID) { $0.controlMode = mode }
    }

    func setFlexibleQuality(
        _ quality: Double,
        jobID: CompressionJob.ID
    ) {
        updateCompressionDraft(jobID: jobID) {
            $0.quality = min(
                FlexibleCompressionSettings.maximumQuality,
                max(FlexibleCompressionSettings.minimumQuality, quality)
            )
        }
    }

    func setFlexibleResolution(
        _ resolution: FlexibleResolution,
        jobID: CompressionJob.ID
    ) {
        updateCompressionDraft(jobID: jobID) { $0.resolution = resolution }
    }

    func setFlexibleFrameRate(
        _ frameRate: FlexibleFrameRate,
        jobID: CompressionJob.ID
    ) {
        updateCompressionDraft(jobID: jobID) { $0.frameRate = frameRate }
    }

    func setKeepsAudio(_ keepsAudio: Bool, jobID: CompressionJob.ID) {
        updateCompressionDraft(jobID: jobID) {
            $0.audioPreference = keepsAudio ? .keep : .remove
        }
    }

    func selectJob(_ jobID: CompressionJob.ID?) {
        guard let jobID else {
            guard jobs.isEmpty else { return }
            selectedJobID = nil
            recomputeScreenState()
            return
        }
        guard job(id: jobID) != nil else { return }
        pendingImportedSelectionID = nil
        selectedJobID = jobID
        recomputeScreenState()
    }

    func canCancel(jobID: CompressionJob.ID) -> Bool {
        guard pendingActionJobIDs.contains(jobID) == false,
              let job = job(id: jobID) else {
            return false
        }
        switch job.state {
        case .draft, .probing, .queued, .running, .finishing, .cancelling:
            return true
        case .ready, .cancelled, .completed, .noBenefit, .failed:
            return false
        }
    }

    func canRetry(jobID: CompressionJob.ID) -> Bool {
        guard pendingActionJobIDs.contains(jobID) == false,
              snapshot.activeJobID != jobID,
              let job = job(id: jobID),
              let retriesProbe = Self.retriesProbe(job) else {
            return false
        }
        return retriesProbe || outputDirectoryURL != nil
    }

    func canRemove(jobID: CompressionJob.ID) -> Bool {
        guard snapshot.activeJobID != jobID,
              pendingActionJobIDs.contains(jobID) == false,
              let job = job(id: jobID) else {
            return false
        }
        switch job.state {
        case .ready, .queued, .cancelled, .completed, .noBenefit, .failed:
            return true
        case .draft, .probing, .running, .finishing, .cancelling:
            return false
        }
    }

    func queuePosition(for jobID: CompressionJob.ID) -> Int? {
        snapshot.queuedJobIDs.firstIndex(of: jobID).map { $0 + 1 }
    }

    @discardableResult
    func createJob(inputURL: URL) async throws -> CompressionJob {
        let job = try await coordinator.createJob(
            inputURL: inputURL,
            id: UUID(),
            createdAt: Date()
        )
        selectedJobID = job.id
        await synchronizeSnapshot()
        return job
    }

    func importVideo(_ inputURL: URL) async {
        await importVideos([inputURL])
    }

    func importVideos(_ inputURLs: [URL]) async {
        guard !isImporting else { return }

        var seenURLs: Set<URL> = []
        var accepted: [URL] = []
        var rejectedCount = 0
        for inputURL in inputURLs {
            let normalized = inputURL.standardizedFileURL
            guard normalized.isFileURL,
                  Self.supportedInputExtensions.contains(
                    normalized.pathExtension.lowercased()
                  ),
                  seenURLs.insert(normalized).inserted else {
                rejectedCount += 1
                continue
            }
            // Keep the exact URL returned by fileImporter/drop. Normalization
            // is only a deduplication key: replacing the original value can
            // discard the security-scoped grant attached by AppKit.
            accepted.append(inputURL)
        }

        guard !accepted.isEmpty else {
            presentValidationError(
                String(localized: "Choose one or more MOV or MP4 videos.")
            )
            return
        }

        let imports = accepted.map { JobQueueImport(inputURL: $0) }
        pendingImportedSelectionID = imports.first?.id
        selectedJobID = pendingImportedSelectionID
        isImporting = true
        validationMessage = nil
        recomputeScreenState()
        defer {
            isImporting = false
            if let pendingImportedSelectionID {
                self.pendingImportedSelectionID = nil
                if job(id: pendingImportedSelectionID) == nil {
                    selectedJobID = snapshot.activeJobID
                        ?? snapshot.jobs.first?.id
                }
            }
            recomputeScreenState()
        }

        do {
            _ = try await coordinator.add(imports)
            await synchronizeSnapshot()
            if rejectedCount > 0 {
                presentValidationError(
                    String(
                        localized: "Some items were skipped. Resizer accepts local MOV and MP4 videos."
                    )
                )
            }
        } catch {
            await synchronizeSnapshot()
            presentValidationError(
                String(
                    localized: "The selected videos could not be added to the queue."
                )
            )
        }
    }

    func reportInputSelectionError() {
        presentValidationError(
            String(localized: "The videos could not be selected.")
        )
    }

    func reportOutputDirectorySelectionError() {
        presentValidationError(
            String(localized: "The output folder could not be selected.")
        )
    }

    func selectOutputDirectory(_ directoryURL: URL) {
        guard directoryURL.isFileURL else {
            presentValidationError(
                String(localized: "Choose a local output folder.")
            )
            return
        }
        outputDirectoryURL = directoryURL
        dismissValidationError()
    }

    func clearOutputDirectory() {
        outputDirectoryURL = nil
    }

    /// Derives and captures one immutable typed recipe per ready job, then
    /// wakes the single FIFO driver. The method returns while encoding runs.
    func start(
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) async {
        guard !isImporting, !isStartingQueue else { return }
        let jobIDs = startableReadyJobs.map(\.id)
        guard !jobIDs.isEmpty else {
            presentValidationError(
                String(localized: "Prepare at least one video before starting.")
            )
            return
        }

        guard let outputPolicy = makeOutputPolicy(
            filenameSuffix: filenameSuffix,
            conflictPolicy: conflictPolicy
        ) else { return }

        isStartingQueue = true
        pendingActionJobIDs.formUnion(jobIDs)
        validationMessage = nil
        defer {
            pendingActionJobIDs.subtract(jobIDs)
            isStartingQueue = false
        }

        var enqueuedCount = 0
        var failedCount = 0
        for jobID in jobIDs {
            do {
                guard let job = job(id: jobID) else {
                    failedCount += 1
                    continue
                }

                guard let primarySettings = try? compressionDraft(
                    for: jobID
                ).primarySettings() else {
                    failedCount += 1
                    continue
                }
                let configuration = makePrimaryConfiguration(
                    for: job,
                    settings: primarySettings,
                    outputPolicy: outputPolicy
                )

                guard let configuration else {
                    failedCount += 1
                    continue
                }
                _ = try await coordinator.enqueue(
                    jobID: jobID,
                    configuration: configuration
                )
                enqueuedCount += 1
            } catch {
                failedCount += 1
            }
        }

        if enqueuedCount > 0 {
            await coordinator.startQueue()
        } else {
            presentValidationError(
                String(localized: "No prepared videos could be queued.")
            )
        }
        await synchronizeSnapshot()
        if failedCount > 0, enqueuedCount > 0 {
            presentValidationError(
                String(
                    localized: "Some prepared videos could not be added to the queue."
                )
            )
        }
    }

    func cancel() async {
        guard let selectedJobID else { return }
        await cancel(jobID: selectedJobID)
    }

    func cancel(jobID: CompressionJob.ID) async {
        guard canCancel(jobID: jobID) else { return }
        await coordinator.cancel(jobID: jobID)
        await synchronizeSnapshot()
    }

    func retry(
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) async {
        guard let selectedJobID else { return }
        await retry(
            jobID: selectedJobID,
            filenameSuffix: filenameSuffix,
            conflictPolicy: conflictPolicy
        )
    }

    func retry(
        jobID: CompressionJob.ID,
        filenameSuffix: String = "-compressed",
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) async {
        guard canRetry(jobID: jobID),
              let job = job(id: jobID),
              let retriesProbe = Self.retriesProbe(job) else {
            return
        }

        let configuration: JobConfiguration?
        if retriesProbe {
            configuration = nil
        } else {
            guard let outputPolicy = makeOutputPolicy(
                    filenameSuffix: filenameSuffix,
                    conflictPolicy: conflictPolicy
                  ),
                  let retryRecipe = retryRecipe(for: job) else {
                return
            }
            configuration = JobConfiguration(
                recipe: retryRecipe,
                outputPolicy: outputPolicy
            )
        }

        pendingActionJobIDs.insert(jobID)
        validationMessage = nil
        defer { pendingActionJobIDs.remove(jobID) }
        do {
            if retriesProbe {
                // Probe failures return to `ready`; the user can then inspect
                // metadata and optionally change the output folder before
                // queueing.
                _ = try await coordinator.prepare(jobID: jobID)
            } else if let configuration {
                _ = try await coordinator.retryQueued(
                    jobID: jobID,
                    configuration: configuration
                )
            }
            await synchronizeSnapshot()
        } catch {
            await synchronizeSnapshot()
            presentValidationError(
                String(localized: "The job could not be retried.")
            )
        }
    }

    func removeSelectedJob() async {
        guard let selectedJobID else { return }
        await removeJob(jobID: selectedJobID)
    }

    func removeJob(jobID: CompressionJob.ID) async {
        guard canRemove(jobID: jobID) else { return }
        pendingActionJobIDs.insert(jobID)
        defer { pendingActionJobIDs.remove(jobID) }
        do {
            try await coordinator.removeJob(jobID: jobID)
            await synchronizeSnapshot()
        } catch {
            presentValidationError(
                String(localized: "This video cannot be removed while it is being processed.")
            )
        }
    }

    func moveSelectedUp() async {
        guard let selectedJobID,
              let index = snapshot.queuedJobIDs.firstIndex(
                of: selectedJobID
              ),
              index > 0 else {
            return
        }
        await moveQueued(
            jobID: selectedJobID,
            before: snapshot.queuedJobIDs[index - 1]
        )
    }

    func moveSelectedDown() async {
        guard let selectedJobID,
              let index = snapshot.queuedJobIDs.firstIndex(
                of: selectedJobID
              ),
              index + 1 < snapshot.queuedJobIDs.count else {
            return
        }
        let successorIndex = index + 2
        let successor = successorIndex < snapshot.queuedJobIDs.count
            ? snapshot.queuedJobIDs[successorIndex]
            : nil
        await moveQueued(jobID: selectedJobID, before: successor)
    }

    func moveQueued(
        jobID: CompressionJob.ID,
        before successorID: CompressionJob.ID?
    ) async {
        do {
            try await coordinator.moveQueued(
                jobID: jobID,
                before: successorID
            )
            await synchronizeSnapshot()
        } catch {
            presentValidationError(
                String(localized: "Only waiting jobs can be reordered.")
            )
        }
    }

    func revealResultInFinder() async {
        guard let selectedJobID else { return }
        await revealResultInFinder(jobID: selectedJobID)
    }

    func openResult(jobID: CompressionJob.ID) async {
        guard let job = job(id: jobID),
              case .completed(let result) = job.state,
              let outputDirectoryURL = job.configuration?.outputPolicy.directoryURL else {
            return
        }
        do {
            try await outputRevealer.open(
                result.outputURL,
                in: outputDirectoryURL
            )
        } catch {
            presentValidationError(
                String(localized: "The compressed copy could not be opened.")
            )
        }
    }

    func revealResultInFinder(jobID: CompressionJob.ID) async {
        guard let job = job(id: jobID),
              case .completed(let result) = job.state,
              let outputDirectoryURL = job.configuration?.outputPolicy.directoryURL else {
            return
        }
        do {
            try await outputRevealer.reveal(
                result.outputURL,
                in: outputDirectoryURL
            )
        } catch {
            presentValidationError(
                String(
                    localized: "The compressed copy could not be shown in Finder."
                )
            )
        }
    }

    func diagnosticText(for jobID: CompressionJob.ID) -> String? {
        guard let job = job(id: jobID),
              case .failed(let failure) = job.state else {
            return nil
        }
        return DiagnosticReportBuilder.make(
            failure: failure,
            inputURL: job.inputURL,
            outputPolicy: job.configuration?.outputPolicy,
            jobID: job.id
        )
    }

    func copyDiagnostics() {
        guard let selectedJobID else { return }
        copyDiagnostics(jobID: selectedJobID)
    }

    func copyDiagnostics(jobID: CompressionJob.ID) {
        guard let diagnostic = diagnosticText(for: jobID),
              !diagnostic.isEmpty else {
            return
        }
        diagnosticCopier.copyDiagnostic(diagnostic)
    }

    func dismissValidationError() {
        validationMessage = nil
        recomputeScreenState()
    }

    func refresh() async {
        await synchronizeSnapshot()
    }

    /// Stops snapshot observation, asks the coordinator to cancel and reap
    /// every active workflow, then captures the terminal state before normal
    /// application termination is allowed to continue.
    func shutdown() async {
        isShuttingDown = true
        pendingFinderReveals.removeAll()
        automaticRevealBatches.removeAll()
        automaticRevealTask?.cancel()
        automaticRevealTask = nil
        observationTask?.cancel()
        observationTask = nil
        await coordinator.shutdown()
        await synchronizeSnapshot()
    }

    private func makeOutputPolicy(
        filenameSuffix: String,
        conflictPolicy: OutputConflictPolicy
    ) -> OutputPolicy? {
        guard let outputDirectoryURL else {
            presentValidationError(
                String(localized: "Choose an output folder before starting.")
            )
            return nil
        }

        do {
            return try OutputPolicy(
                directoryURL: outputDirectoryURL,
                filenameSuffix: filenameSuffix,
                conflictPolicy: conflictPolicy
            )
        } catch {
            presentValidationError(
                String(
                    localized: "Check the output filename suffix."
                )
            )
            return nil
        }
    }

    private func makePrimaryConfiguration(
        for job: CompressionJob,
        settings: PrimaryCompressionSettings,
        outputPolicy: OutputPolicy
    ) -> JobConfiguration? {
        guard let mediaInfo = job.mediaInfo else {
            return nil
        }
        do {
            return JobConfiguration(
                recipe: try AutomaticCompressionPolicy().recipe(
                    for: mediaInfo,
                    settings: settings
                ),
                outputPolicy: outputPolicy
            )
        } catch {
            presentValidationError(
                String(localized: "The compression settings could not be prepared.")
            )
            return nil
        }
    }

    private func retryRecipe(for job: CompressionJob) -> CompressionRecipe? {
        if let recipe = job.configuration?.recipe {
            return recipe
        }
        guard let mediaInfo = job.mediaInfo else { return nil }
        guard let settings = try? compressionDraft(
            for: job.id
        ).primarySettings() else {
            return nil
        }
        return try? AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: settings
        )
    }

    private func updateCompressionDraft(
        jobID: CompressionJob.ID,
        _ update: (inout CompressionDraftSettings) -> Void
    ) {
        guard canEditCompression(jobID: jobID) else { return }
        var draft = compressionDraft(for: jobID)
        update(&draft)
        compressionDrafts[jobID] = draft
    }

    private func synchronizeSnapshot() async {
        consume(await coordinator.snapshot())
    }

    private func consume(_ snapshot: CompressionSnapshot) {
        if let lastConsumedSnapshotRevision,
           snapshot.revision < lastConsumedSnapshotRevision {
            return
        }
        lastConsumedSnapshotRevision = snapshot.revision
        self.snapshot = snapshot

        let knownJobIDs = Set(snapshot.jobs.map(\.id))
        compressionDrafts = compressionDrafts.filter {
            knownJobIDs.contains($0.key)
        }
        for job in snapshot.jobs {
            if compressionDrafts[job.id] == nil {
                compressionDrafts[job.id] = CompressionDraftSettings()
            }
        }

        let preservesPendingImportedSelection: Bool
        if let pendingImportedSelectionID {
            if snapshot.jobs.contains(where: {
                $0.id == pendingImportedSelectionID
            }) {
                self.pendingImportedSelectionID = nil
                preservesPendingImportedSelection = false
            } else {
                preservesPendingImportedSelection =
                    selectedJobID == pendingImportedSelectionID
            }
        } else {
            preservesPendingImportedSelection = false
        }

        if !preservesPendingImportedSelection {
            if let selectedJobID, job(id: selectedJobID) == nil {
                self.selectedJobID = snapshot.activeJobID
                    ?? snapshot.jobs.first?.id
            } else if selectedJobID == nil {
                selectedJobID = snapshot.activeJobID
                    ?? snapshot.jobs.first?.id
            }
        }

        updateETA(from: activeJob)
        recomputeScreenState()
        collectAutomaticFinderReveals(from: snapshot)
    }

    private func collectAutomaticFinderReveals(
        from snapshot: CompressionSnapshot
    ) {
        for job in snapshot.jobs {
            guard case .completed(let result) = job.state,
                  let outputDirectoryURL = job.configuration?
                    .outputPolicy.directoryURL else {
                continue
            }
            let completionKey = FinderRevealCompletionKey(
                jobID: job.id,
                standardizedOutputPath: result.outputURL
                    .standardizedFileURL.path
            )
            guard seenFinderRevealCompletions.insert(
                completionKey
            ).inserted else {
                continue
            }
            let candidate = PendingFinderReveal(
                outputURL: result.outputURL,
                outputDirectoryURL: outputDirectoryURL
            )
            pendingFinderReveals.append(candidate)
        }

        guard !snapshot.isDraining,
              !pendingFinderReveals.isEmpty else {
            return
        }

        let reveals = pendingFinderReveals
        pendingFinderReveals.removeAll()
        guard !isShuttingDown,
              automaticallyRevealsCompletedOutputs() else {
            return
        }

        automaticRevealBatches.append(reveals)
        startAutomaticFinderRevealWorkerIfNeeded()
    }

    private func startAutomaticFinderRevealWorkerIfNeeded() {
        guard automaticRevealTask == nil else { return }
        automaticRevealTask = Task { [weak self] in
            await self?.drainAutomaticFinderRevealBatches()
        }
    }

    private func drainAutomaticFinderRevealBatches() async {
        defer { automaticRevealTask = nil }
        while !Task.isCancelled,
              !isShuttingDown,
              !automaticRevealBatches.isEmpty {
            let reveals = automaticRevealBatches.removeFirst()
            await performAutomaticFinderReveal(reveals)
        }
    }

    private func performAutomaticFinderReveal(
        _ reveals: [PendingFinderReveal]
    ) async {
        guard !Task.isCancelled, !isShuttingDown else { return }
        do {
            try await outputRevealer.reveal(
                reveals.map(\.outputURL),
                in: reveals.map(\.outputDirectoryURL)
            )
        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            let message = reveals.count == 1
                ? String(
                    localized: "The compressed copy could not be shown in Finder."
                )
                : String(
                    localized: "The compressed copies could not be shown in Finder."
                )
            presentValidationError(
                message
            )
        }
    }

    private func recomputeScreenState() {
        guard let currentJob else {
            if let validationMessage {
                screenState = .validationError(validationMessage)
            } else if isImporting {
                screenState = .importing
            } else {
                screenState = .empty
            }
            return
        }

        switch currentJob.state {
        case .draft:
            screenState = .importing
        case .probing:
            screenState = .probing(currentJob)
        case .ready:
            screenState = .ready(currentJob)
        case .queued where snapshot.activeJobID == currentJob.id:
            screenState = .running(currentJob, .preparing)
        case .queued:
            screenState = .queued(
                currentJob,
                position: queuePosition(for: currentJob.id) ?? 1
            )
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
        case .noBenefit(let result):
            screenState = .noBenefit(currentJob, result)
        case .failed(let failure):
            screenState = .failure(currentJob, .transcode(failure))
        }
    }

    private func presentValidationError(_ message: String) {
        validationMessage = message
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

        if etaJobID != job.id {
            etaJobID = job.id
            etaSpeedSamples.removeAll(keepingCapacity: true)
            etaLastProcessedMicroseconds = nil
        } else if let last = etaLastProcessedMicroseconds {
            if progress.processedMicroseconds < last {
                etaSpeedSamples.removeAll(keepingCapacity: true)
            } else if progress.processedMicroseconds == last {
                // Queue mutations publish the active job again without new
                // progress. Do not treat that unrelated snapshot as a rewind
                // or duplicate speed sample.
                return
            }
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

    private static let supportedInputExtensions: Set<String> = [
        "mov", "mp4",
    ]

    private static func retriesProbe(_ job: CompressionJob) -> Bool? {
        switch job.state {
        case .failed(let failure):
            return failure.retryTarget == .probing
        case .cancelled:
            return job.mediaInfo == nil
        case .draft, .probing, .ready, .queued, .running, .finishing,
             .cancelling, .completed, .noBenefit:
            return nil
        }
    }
}
