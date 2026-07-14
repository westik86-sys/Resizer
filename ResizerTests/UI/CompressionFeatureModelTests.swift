import Foundation
import Testing
@testable import Resizer

@Suite("Compression queue feature model", .serialized)
@MainActor
struct CompressionFeatureModelTests {
    @Test("Batch import keeps supported files in selection order")
    func batchImportIsAdditiveAndOrdered() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()

        await model.importVideos([
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/not-video.avi"),
            URL(fileURLWithPath: "/tmp/two.MOV"),
        ])

        #expect(model.jobs.map(\.inputURL.lastPathComponent) == [
            "one.mp4", "two.MOV",
        ])
        #expect(model.jobs.allSatisfy { $0.state == .ready })
        #expect(model.selectedJobID == model.jobs.first?.id)
        #expect(model.validationMessage?.contains("skipped") == true)
        let calls = await coordinator.recordedCalls()
        #expect(calls.addedInputs.map(\.lastPathComponent) == [
            "one.mp4", "two.MOV",
        ])
        #expect(calls.prepareCount == 2)
        #expect(calls.startQueueCount == 0)
    }

    @Test("Import deduplicates normalized paths without replacing the original URL")
    func importPreservesOriginalURLWhileDeduplicating() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        let originalURL = URL(
            fileURLWithPath: "/tmp/security-scope/../source.mp4"
        )
        let duplicateURL = originalURL.standardizedFileURL

        #expect(originalURL != duplicateURL)
        await model.importVideos([originalURL, duplicateURL])

        let job = try #require(model.jobs.first)
        let calls = await coordinator.recordedCalls()
        #expect(model.jobs.count == 1)
        #expect(job.inputURL == originalURL)
        #expect(calls.addedInputs == [originalURL])
        #expect(model.validationMessage?.contains("skipped") == true)
    }

    @Test("Adding a batch while another job runs never replaces it")
    func addWhileRunningIsNonDestructive() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/active.mp4"))
        let activeID = try #require(model.selectedJobID)
        try await coordinator.replaceWithRunningJob(jobID: activeID)
        #expect(await eventually { model.snapshot.activeJobID == activeID })

        await model.importVideos([
            URL(fileURLWithPath: "/tmp/second.mov"),
            URL(fileURLWithPath: "/tmp/third.mp4"),
        ])

        #expect(model.jobs.count == 3)
        #expect(model.job(id: activeID)?.state.phase == .running)
        #expect(model.selectedJobID != activeID)
        #expect((await coordinator.recordedCalls()).cancelledJobIDs.isEmpty)
    }

    @Test("Start captures one typed configuration for every ready job")
    func startCapturesBatchConfiguration() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mov"),
        ])

        await model.start()
        #expect((await coordinator.recordedCalls()).enqueuedJobIDs.isEmpty)
        #expect(model.validationMessage?.contains("output folder") == true)

        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        model.applyPreset(.smallFile)
        await model.start(
            filenameSuffix: "-web",
            conflictPolicy: .fail
        )

        let calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs == model.jobs.map(\.id))
        #expect(calls.startQueueCount == 1)
        #expect(calls.configurations.count == 2)
        for configuration in calls.configurations.values {
            #expect(configuration.recipe == (
                try CompressionRecipe(preset: .smallFile)
            ))
            #expect(configuration.outputPolicy.filenameSuffix == "-web")
            #expect(configuration.outputPolicy.conflictPolicy == .fail)
        }
        #expect(model.snapshot.activeJobID == model.jobs.first?.id)
        #expect(model.snapshot.queuedJobIDs == [model.jobs[1].id])
    }

    @Test("Overlapping start calls enqueue and wake the queue exactly once")
    func overlappingStartsAreIdempotent() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/once.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let enqueueGate = SynchronousCallGate()
        await coordinator.gateNextEnqueue(enqueueGate)

        let firstStart = Task { await model.start() }
        await enqueueGate.waitUntilEntered()
        #expect(model.isStartingQueue)

        await model.start()
        #expect(model.isStartingQueue)

        enqueueGate.release()
        await firstStart.value
        let calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs == [jobID])
        #expect(calls.startQueueCount == 1)
        #expect(calls.configurations.count == 1)
    }

    @Test("A ready snapshot cannot start before its import finishes")
    func readySnapshotWaitsForImportCompletion() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterReady(prepareGate)

        let importTask = Task { @MainActor in
            await model.importVideo(
                URL(fileURLWithPath: "/tmp/preparing.mp4")
            )
        }
        let jobID = await prepareGate.waitUntilEntered()
        #expect(await eventually {
            model.isImporting && model.job(id: jobID)?.state == .ready
        })

        #expect(!model.canStart)
        await model.start()
        var calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)

        await prepareGate.release()
        await importTask.value

        #expect(model.canStart)
        calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
    }

    @Test("A ready probe-retry snapshot cannot start before retry finishes")
    func readySnapshotWaitsForProbeRetryCompletion() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(
            URL(fileURLWithPath: "/tmp/retrying-probe.mp4")
        )
        let jobID = try #require(model.selectedJobID)
        try await coordinator.replaceWithProbeFailure(jobID: jobID)
        #expect(await eventually {
            model.job(id: jobID)?.state.phase == .failed
        })
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterReady(prepareGate)

        let retryTask = Task { @MainActor in
            await model.retry(jobID: jobID)
        }
        #expect(await prepareGate.waitUntilEntered() == jobID)
        #expect(await eventually {
            model.pendingActionJobIDs.contains(jobID)
                && model.job(id: jobID)?.state == .ready
        })

        #expect(!model.canStart)
        await model.start()
        var calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)

        await prepareGate.release()
        await retryTask.value

        #expect(model.canStart)
        calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
    }

    @Test("Stale import snapshots preserve pending selection until user selects")
    func staleImportSnapshotPreservesPendingSelection() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/existing.mp4"))
        let existingID = try #require(model.selectedJobID)
        let addGate = AsyncCallGate<[CompressionJob.ID]>()
        await coordinator.gateNextAddBeforeCreate(addGate)

        let importTask = Task { @MainActor in
            await model.importVideo(URL(fileURLWithPath: "/tmp/new.mp4"))
        }
        let importedID = try #require(
            await addGate.waitUntilEntered().first
        )

        // A valid concurrent queue update does not contain the not-yet-added
        // import ID. Consuming it must not replace the pending selection.
        try await coordinator.replaceWithRunningJob(jobID: existingID)
        #expect(await eventually {
            model.snapshot.activeJobID == existingID
        })
        #expect(model.selectedJobID == importedID)

        // An explicit user choice wins over the automatic import selection.
        model.selectJob(existingID)
        await addGate.release()
        await importTask.value

        #expect(model.selectedJobID == existingID)
        #expect(model.job(id: importedID)?.state == .ready)
    }

    @Test("A lower revision cannot overtake a completed import")
    func lowerRevisionCannotOvertakeCompletedImport() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/old.mp4"))
        let staleSnapshot = await coordinator.snapshot()

        await model.importVideo(URL(fileURLWithPath: "/tmp/fresh.mp4"))
        let importedID = try #require(model.selectedJobID)
        let freshSnapshot = model.snapshot
        #expect(freshSnapshot.revision > staleSnapshot.revision)
        #expect(freshSnapshot.jobs.count == 2)
        #expect(model.job(id: importedID)?.inputURL.lastPathComponent == "fresh.mp4")

        // Deliver the captured snapshot through the same direct-sync seam
        // used by model actions. This avoids scheduler timing in the stream
        // while reproducing an older response arriving after the import.
        await coordinator.replayOnNextSnapshotRead(staleSnapshot)
        await model.refresh()

        #expect(model.snapshot == freshSnapshot)
        #expect(model.selectedJobID == importedID)
        #expect(model.jobs.map(\.inputURL.lastPathComponent) == [
            "old.mp4", "fresh.mp4",
        ])
    }

    @Test("Cancel targets one waiting job without disturbing the active job")
    func explicitQueuedCancellation() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
        ])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        let activeID = try #require(model.snapshot.activeJobID)
        let waitingID = try #require(model.snapshot.queuedJobIDs.first)

        await model.cancel(jobID: waitingID)

        #expect(model.job(id: waitingID)?.state == .cancelled)
        #expect(model.job(id: activeID)?.state.phase == .running)
        #expect((await coordinator.recordedCalls()).cancelledJobIDs == [
            waitingID,
        ])
    }

    @Test("Waiting jobs can be reordered and removed with stable selection")
    func reorderAndRemoveWaitingJobs() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
            URL(fileURLWithPath: "/tmp/c.mp4"),
        ])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        let activeID = try #require(model.snapshot.activeJobID)
        let secondID = model.snapshot.queuedJobIDs[0]
        let thirdID = model.snapshot.queuedJobIDs[1]
        model.selectJob(thirdID)

        await model.moveSelectedUp()
        #expect(model.snapshot.queuedJobIDs == [thirdID, secondID])

        await model.removeSelectedQueuedJob()
        #expect(model.job(id: thirdID) == nil)
        #expect(model.snapshot.queuedJobIDs == [secondID])
        #expect(model.selectedJobID == activeID)
        let calls = await coordinator.recordedCalls()
        #expect(calls.removedJobIDs == [thirdID])
    }

    @Test("Retry preserves identity and copies only bounded diagnostics")
    func retryAndDiagnostics() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let copier = DiagnosticCopierSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            diagnosticCopier: copier
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))
        let jobID = try #require(model.selectedJobID)
        let diagnostic = try BoundedDiagnostic(
            text: "bounded encoder tail",
            utf8ByteLimit: 64,
            wasTruncated: false
        )
        try await coordinator.replaceWithEncodeFailure(
            jobID: jobID,
            diagnostic: diagnostic
        )
        #expect(await eventually { model.diagnosticText == diagnostic.text })

        model.copyDiagnostics(jobID: jobID)
        #expect(copier.copiedTexts == [diagnostic.text])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/retry", isDirectory: true)
        )
        await model.retry(jobID: jobID, filenameSuffix: "-retry")

        let calls = await coordinator.recordedCalls()
        #expect(calls.retriedJobIDs == [jobID])
        #expect(calls.configurations[jobID]?.outputPolicy.filenameSuffix == "-retry")
        #expect(model.job(id: jobID) != nil)
        #expect(model.snapshot.activeJobID == jobID)
    }

    @Test("Probe failure retries preparation without requiring an output folder")
    func probeFailureRetryReturnsToReady() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/probe-failure.mp4"))
        let jobID = try #require(model.selectedJobID)
        try await coordinator.replaceWithProbeFailure(jobID: jobID)
        #expect(await eventually {
            model.job(id: jobID)?.state.phase == .failed
        })
        let prepareCountBeforeRetry = await coordinator.recordedCalls()
            .prepareCount

        #expect(model.outputDirectoryURL == nil)
        #expect(model.canRetry(jobID: jobID))
        await model.retry(jobID: jobID)

        let calls = await coordinator.recordedCalls()
        #expect(calls.prepareCount == prepareCountBeforeRetry + 1)
        #expect(calls.retriedJobIDs.isEmpty)
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
        #expect(model.job(id: jobID)?.state == .ready)
        #expect(model.selectedJobID == jobID)
    }

    @Test("ETA follows the active encode instead of sidebar selection")
    func etaUsesActiveJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/active.mp4"),
            URL(fileURLWithPath: "/tmp/selected.mp4"),
        ])
        let activeID = model.jobs[0].id
        let selectedID = model.jobs[1].id
        try await coordinator.replaceWithRunningJob(jobID: activeID)
        model.selectJob(selectedID)

        for sample in [(3_000_000, 2.0), (4_000_000, 2.1), (5_000_000, 1.9)] {
            try await coordinator.sendProgress(
                jobID: activeID,
                processedMicroseconds: Int64(sample.0),
                totalMicroseconds: 20_000_000,
                speed: sample.1
            )
            #expect(await eventually {
                model.activeProgressMicroseconds == Int64(sample.0)
            })
        }

        #expect(model.selectedJobID == selectedID)
        #expect(model.estimatedRemainingSeconds == 7.5)
    }

    @Test("Unchanged active progress snapshot preserves a mature ETA")
    func unchangedProgressSnapshotPreservesETA() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/active.mp4"))
        let activeID = try #require(model.selectedJobID)
        try await coordinator.replaceWithRunningJob(jobID: activeID)

        for sample in [(3_000_000, 2.0), (4_000_000, 2.1), (5_000_000, 1.9)] {
            try await coordinator.sendProgress(
                jobID: activeID,
                processedMicroseconds: Int64(sample.0),
                totalMicroseconds: 20_000_000,
                speed: sample.1
            )
            #expect(await eventually {
                model.activeProgressMicroseconds == Int64(sample.0)
            })
        }
        let matureETA = try #require(model.estimatedRemainingSeconds)

        await model.refresh()

        #expect(model.estimatedRemainingSeconds == matureETA)
    }

    @Test("Nil selection cannot deselect a nonempty queue")
    func nilSelectionPreservesExistingSelection() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/first.mp4"),
            URL(fileURLWithPath: "/tmp/second.mp4"),
        ])
        let secondID = model.jobs[1].id
        model.selectJob(secondID)

        model.selectJob(nil)

        #expect(model.selectedJobID == secondID)
        #expect(model.currentJob?.id == secondID)
    }

    @Test("Completed results can be revealed by explicit queue identity")
    func revealExplicitCompletedJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let revealer = OutputRevealerSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            outputRevealer: revealer
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/done.mp4"),
            URL(fileURLWithPath: "/tmp/other.mp4"),
        ])
        let completedID = model.jobs[0].id
        let otherID = model.jobs[1].id
        let outputURL = URL(fileURLWithPath: "/tmp/export/done.mp4")
        try await coordinator.replaceWithCompletedJob(
            jobID: completedID,
            outputURL: outputURL
        )
        #expect(await eventually {
            guard let completed = model.job(id: completedID),
                  case .completed = completed.state else {
                return false
            }
            return true
        })
        model.selectJob(otherID)

        model.revealResultInFinder(jobID: completedID)

        #expect(revealer.revealedURLs == [outputURL])
        #expect(model.selectedJobID == otherID)
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private extension CompressionFeatureModel {
    var activeProgressMicroseconds: Int64? {
        guard let activeJob,
              case .running(let progress) = activeJob.state else {
            return nil
        }
        return progress?.processedMicroseconds
    }
}

@MainActor
private final class OutputRevealerSpy: OutputRevealing {
    private(set) var revealedURLs: [URL] = []

    func reveal(_ outputURL: URL) {
        revealedURLs.append(outputURL)
    }
}

@MainActor
private final class DiagnosticCopierSpy: DiagnosticCopying {
    private(set) var copiedTexts: [String] = []

    func copyDiagnostic(_ text: String) {
        copiedTexts.append(text)
    }
}

private final class SynchronousCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() {
        lock.lock()
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
        releaseSignal.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didEnter {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        releaseSignal.signal()
    }
}

private actor AsyncCallGate<Value: Sendable> {
    private var enteredValue: Value?
    private var entryWaiters: [CheckedContinuation<Value, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func enterAndWait(_ value: Value) async {
        enteredValue = value
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilEntered() async -> Value {
        if let enteredValue { return enteredValue }
        return await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        waiter?.resume()
    }
}

private actor QueueFeatureCoordinatorFake: JobQueueCoordinating {
    nonisolated struct Calls: Sendable {
        var addedInputs: [URL] = []
        var prepareCount = 0
        var enqueuedJobIDs: [CompressionJob.ID] = []
        var configurations: [CompressionJob.ID: JobConfiguration] = [:]
        var startQueueCount = 0
        var retriedJobIDs: [CompressionJob.ID] = []
        var cancelledJobIDs: [CompressionJob.ID] = []
        var removedJobIDs: [CompressionJob.ID] = []
    }

    private var calls = Calls()
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []
    private var activeJobID: CompressionJob.ID?
    private var snapshotRevision: UInt64 = 0
    private var replayedSnapshotForNextDirectRead: CompressionSnapshot?
    private var continuations: [
        UUID: AsyncStream<CompressionSnapshot>.Continuation
    ] = [:]
    private var hasSubscriber = false
    private var subscriberWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextEnqueueGate: SynchronousCallGate?
    private var nextPrepareAfterReadyGate: AsyncCallGate<CompressionJob.ID>?
    private var nextAddBeforeCreateGate: AsyncCallGate<[CompressionJob.ID]>?

    @discardableResult
    func add(
        _ imports: [JobQueueImport]
    ) async throws -> [CompressionJob.ID] {
        if let gate = nextAddBeforeCreateGate {
            nextAddBeforeCreateGate = nil
            await gate.enterAndWait(imports.map(\.id))
        }
        for item in imports {
            _ = try createJob(
                inputURL: item.inputURL,
                id: item.id,
                createdAt: item.createdAt
            )
            calls.addedInputs.append(item.inputURL)
        }
        for item in imports {
            _ = try await prepare(jobID: item.id)
        }
        return imports.map(\.id)
    }

    func createJob(
        inputURL: URL,
        id: CompressionJob.ID,
        createdAt: Date
    ) throws -> CompressionJob {
        let job = try CompressionJob(
            id: id,
            inputURL: inputURL,
            createdAt: createdAt
        )
        jobsByID[id] = job
        jobOrder.append(id)
        publish()
        return job
    }

    func prepare(jobID: CompressionJob.ID) async throws -> CompressionJob {
        calls.prepareCount += 1
        var job = try requireJob(jobID)
        try job.transition(to: .probing)
        jobsByID[jobID] = job
        publish()
        try job.recordMediaInfo(TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        jobsByID[jobID] = job
        publish()
        if let gate = nextPrepareAfterReadyGate {
            nextPrepareAfterReadyGate = nil
            await gate.enterAndWait(jobID)
        }
        return job
    }

    @discardableResult
    func enqueue(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) throws -> CompressionJob {
        if let gate = nextEnqueueGate {
            nextEnqueueGate = nil
            gate.enterAndWait()
        }
        var job = try requireJob(jobID)
        switch job.state {
        case .ready:
            break
        case .failed(let failure) where failure.retryTarget == .ready:
            try job.transition(to: .ready)
        case .cancelled where job.mediaInfo != nil:
            try job.transition(to: .ready)
        default:
            throw CompressionWorkflowError.workflowStateChanged(job.state.phase)
        }
        try job.configure(configuration)
        try job.transition(to: .queued)
        jobsByID[jobID] = job
        calls.enqueuedJobIDs.append(jobID)
        calls.configurations[jobID] = configuration
        publish()
        return job
    }

    func startQueue() {
        calls.startQueueCount += 1
        guard activeJobID == nil,
              let jobID = firstWaitingJobID(),
              var job = jobsByID[jobID] else {
            publish()
            return
        }
        activeJobID = jobID
        try? job.transition(to: .running(progress: nil))
        jobsByID[jobID] = job
        publish()
    }

    @discardableResult
    func retryQueued(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        var job = try requireJob(jobID)
        switch job.state {
        case .failed(let failure) where failure.retryTarget == .probing:
            let old = job
            job = try CompressionJob(
                id: old.id,
                inputURL: old.inputURL,
                createdAt: old.createdAt
            )
            try job.transition(to: .probing)
            try job.recordMediaInfo(TestFixtures.mediaInfo())
            try job.transition(to: .ready)
        case .cancelled where job.mediaInfo == nil:
            let old = job
            job = try CompressionJob(
                id: old.id,
                inputURL: old.inputURL,
                createdAt: old.createdAt
            )
            try job.transition(to: .probing)
            try job.recordMediaInfo(TestFixtures.mediaInfo())
            try job.transition(to: .ready)
        case .failed, .cancelled:
            try job.transition(to: .ready)
        default:
            throw CompressionWorkflowError.workflowStateChanged(job.state.phase)
        }
        jobsByID[jobID] = job
        jobOrder.removeAll { $0 == jobID }
        jobOrder.append(jobID)
        calls.retriedJobIDs.append(jobID)
        let queued = try enqueue(
            jobID: jobID,
            configuration: configuration
        )
        startQueue()
        return queued
    }

    func moveQueued(
        jobID: CompressionJob.ID,
        before successorID: CompressionJob.ID?
    ) throws {
        try requireWaiting(jobID)
        if let successorID { try requireWaiting(successorID) }
        jobOrder.removeAll { $0 == jobID }
        if let successorID,
           let index = jobOrder.firstIndex(of: successorID) {
            jobOrder.insert(jobID, at: index)
        } else {
            jobOrder.append(jobID)
        }
        publish()
    }

    func removeQueued(jobID: CompressionJob.ID) throws {
        try requireWaiting(jobID)
        jobsByID.removeValue(forKey: jobID)
        jobOrder.removeAll { $0 == jobID }
        calls.removedJobIDs.append(jobID)
        publish()
    }

    func cancel(jobID: CompressionJob.ID) async {
        calls.cancelledJobIDs.append(jobID)
        guard var job = jobsByID[jobID] else { return }
        do {
            switch job.state {
            case .running(let progress):
                try job.transition(to: .cancelling(lastProgress: progress))
                try job.transition(to: .cancelled)
            case .draft, .probing, .ready, .queued:
                try job.transition(to: .cancelled)
            case .finishing, .cancelling, .cancelled, .completed, .failed:
                return
            }
            jobsByID[jobID] = job
            if activeJobID == jobID { activeJobID = nil }
            publish()
        } catch {
            Issue.record("Fake cancellation failed: \(error)")
        }
    }

    func snapshot() -> CompressionSnapshot {
        if let replayedSnapshotForNextDirectRead {
            self.replayedSnapshotForNextDirectRead = nil
            return replayedSnapshotForNextDirectRead
        }
        return currentSnapshot()
    }

    func replayOnNextSnapshotRead(_ snapshot: CompressionSnapshot) {
        replayedSnapshotForNextDirectRead = snapshot
    }

    private func currentSnapshot() -> CompressionSnapshot {
        CompressionSnapshot(
            jobs: jobOrder.compactMap { jobsByID[$0] },
            activeJobID: activeJobID,
            isDraining: activeJobID != nil,
            revision: snapshotRevision
        )
    }

    func snapshots() -> AsyncStream<CompressionSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<CompressionSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        pair.continuation.yield(currentSnapshot())
        hasSubscriber = true
        let waiters = subscriberWaiters
        subscriberWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return pair.stream
    }

    func waitUntilSubscribed() async {
        if hasSubscriber { return }
        await withCheckedContinuation { continuation in
            subscriberWaiters.append(continuation)
        }
    }

    func recordedCalls() -> Calls {
        calls
    }

    func gateNextEnqueue(_ gate: SynchronousCallGate) {
        nextEnqueueGate = gate
    }

    func gateNextPrepareAfterReady(
        _ gate: AsyncCallGate<CompressionJob.ID>
    ) {
        nextPrepareAfterReadyGate = gate
    }

    func gateNextAddBeforeCreate(
        _ gate: AsyncCallGate<[CompressionJob.ID]>
    ) {
        nextAddBeforeCreateGate = gate
    }

    func replaceWithRunningJob(jobID: CompressionJob.ID) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        jobsByID[jobID] = job
        activeJobID = jobID
        publish()
    }

    func replaceWithEncodeFailure(
        jobID: CompressionJob.ID,
        diagnostic: BoundedDiagnostic
    ) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(
            to: .failed(
                TranscodeFailure(
                    stage: .encode,
                    reason: .processFailed(exitCode: 1),
                    diagnosticTail: diagnostic
                )
            )
        )
        jobsByID[jobID] = job
        activeJobID = nil
        publish()
    }

    func replaceWithProbeFailure(jobID: CompressionJob.ID) throws {
        let old = try requireJob(jobID)
        var job = try CompressionJob(
            id: old.id,
            inputURL: old.inputURL,
            createdAt: old.createdAt
        )
        try job.transition(to: .probing)
        try job.transition(
            to: .failed(
                TranscodeFailure(
                    stage: .probe,
                    reason: .invalidMedia,
                    diagnosticTail: nil
                )
            )
        )
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func replaceWithCompletedJob(
        jobID: CompressionJob.ID,
        outputURL: URL
    ) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(to: .finishing(.validating))
        try job.transition(to: .finishing(.committing))
        try job.transition(
            to: .completed(
                try CompressionResult(
                    outputURL: outputURL,
                    outputByteCount: 2_048,
                    elapsed: .seconds(2)
                )
            )
        )
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func sendProgress(
        jobID: CompressionJob.ID,
        processedMicroseconds: Int64,
        totalMicroseconds: Int64,
        speed: Double
    ) throws {
        var job = try requireJob(jobID)
        try job.updateProgress(
            TranscodeProgress(
                processedMicroseconds: processedMicroseconds,
                totalMicroseconds: totalMicroseconds,
                speed: speed
            )
        )
        jobsByID[jobID] = job
        publish()
    }

    private func makeReadyJob(
        jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        let old = try requireJob(jobID)
        var job = try CompressionJob(
            id: old.id,
            inputURL: old.inputURL,
            createdAt: old.createdAt
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        return job
    }

    private func firstWaitingJobID() -> CompressionJob.ID? {
        jobOrder.first { id in
            guard id != activeJobID,
                  let job = jobsByID[id],
                  case .queued = job.state else {
                return false
            }
            return true
        }
    }

    private func requireWaiting(_ jobID: CompressionJob.ID) throws {
        let job = try requireJob(jobID)
        guard jobID != activeJobID,
              case .queued = job.state else {
            throw CompressionCoordinatorError.queueMutationRequiresQueued(
                jobID
            )
        }
    }

    private func requireJob(
        _ jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        guard let job = jobsByID[jobID] else {
            throw CompressionCoordinatorError.jobNotFound(jobID)
        }
        return job
    }

    private func publish() {
        snapshotRevision &+= 1
        let value = currentSnapshot()
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
