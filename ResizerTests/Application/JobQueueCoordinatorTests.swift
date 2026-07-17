import Foundation
import Testing
@testable import Resizer

@Suite("Session job queue")
struct JobQueueCoordinatorTests {
    @Test("Admission order, not import order, defines FIFO")
    func enqueueOrderDefinesFIFO() async throws {
        let harness = try await QueueHarness.make()
        let imported = [UUID(), UUID(), UUID()]
        _ = try await harness.coordinator.add(
            imported.map {
                JobQueueImport(inputURL: QueueHarness.inputURL(for: $0), id: $0)
            }
        )
        let admitted = [imported[2], imported[0], imported[1]]
        for id in admitted {
            _ = try await harness.coordinator.enqueue(
                jobID: id,
                configuration: harness.configuration
            )
        }

        #expect(await harness.coordinator.snapshot().queuedJobIDs == admitted)
        await harness.coordinator.startQueue()
        for id in admitted {
            try await harness.transcoder.waitUntilStarted(id)
            try await harness.transcoder.succeed(id)
        }
        try await harness.waitUntilIdle()

        #expect(await harness.transcoder.startedJobIDs() == admitted)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Snapshot exposes the active job for the complete queue drain")
    func activeJobLifecycle() async throws {
        let harness = try await QueueHarness.make()
        let id = UUID()
        try await harness.addAndEnqueue([id])

        let beforeStart = await harness.coordinator.snapshot()
        #expect(beforeStart.activeJobID == nil)
        #expect(!beforeStart.isDraining)

        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(id)

        let blocked = await harness.coordinator.snapshot()
        #expect(blocked.activeJobID == id)
        #expect(blocked.isDraining)
        #expect(blocked.queuedJobIDs.isEmpty)

        try await harness.transcoder.succeed(id)
        try await harness.waitUntilIdle()

        let drained = await harness.coordinator.snapshot()
        #expect(drained.activeJobID == nil)
        #expect(!drained.isDraining)
        #expect(drained.job(id: id)?.state.phase == .completed)
    }

    @Test("Queue is FIFO with one transcode and one start per attempt")
    func fifoAndConcurrencyLimit() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await harness.coordinator.startQueue()
                }
            }
        }

        try await harness.transcoder.waitUntilStarted(ids[0])
        #expect(await harness.transcoder.startedJobIDs() == [ids[0]])
        #expect(await harness.coordinator.snapshot().queuedJobIDs == [ids[1], ids[2]])

        try await harness.transcoder.succeed(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])
        try await harness.transcoder.succeed(ids[1])
        try await harness.transcoder.waitUntilStarted(ids[2])
        try await harness.transcoder.succeed(ids[2])
        try await harness.waitUntilIdle()

        #expect(await harness.transcoder.startedJobIDs() == ids)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
        for id in ids {
            #expect(await harness.transcoder.startCount(for: id) == 1)
        }
        #expect(
            await harness.coordinator.snapshot().jobs.allSatisfy {
                $0.state.phase == .completed
            }
        )
    }

    @Test("Cancelling queued and running jobs advances to the next job")
    func cancelQueuedAndRunning() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(ids[0])

        await harness.coordinator.cancel(jobID: ids[1])
        #expect(
            await harness.coordinator.snapshot().job(id: ids[1])?.state.phase
                == .cancelled
        )
        #expect(!(await harness.transcoder.cancelledJobIDs()).contains(ids[1]))

        await harness.coordinator.cancel(jobID: ids[0])
        try await harness.transcoder.waitUntilStarted(ids[2])
        try await harness.transcoder.succeed(ids[2])
        try await harness.waitUntilIdle()

        let snapshot = await harness.coordinator.snapshot()
        #expect(snapshot.job(id: ids[0])?.state.phase == .cancelled)
        #expect(snapshot.job(id: ids[1])?.state.phase == .cancelled)
        #expect(snapshot.job(id: ids[2])?.state.phase == .completed)
        #expect(await harness.transcoder.startedJobIDs() == [ids[0], ids[2]])
        #expect((await harness.transcoder.cancelledJobIDs()).contains(ids[0]))
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("A failed job does not stop the next queued job")
    func failureContinuation() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()

        try await harness.transcoder.waitUntilStarted(ids[0])
        try await harness.transcoder.fail(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])
        try await harness.transcoder.succeed(ids[1])
        try await harness.waitUntilIdle()

        let snapshot = await harness.coordinator.snapshot()
        #expect(snapshot.job(id: ids[0])?.state.phase == .failed)
        #expect(snapshot.job(id: ids[1])?.state.phase == .completed)
        #expect(await harness.transcoder.startedJobIDs() == ids)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("A NoBenefit job advances FIFO to the next queued job")
    func noBenefitContinuation() async throws {
        let ids = [UUID(), UUID()]
        let harness = try await QueueHarness.make(
            candidateByteCounts: [
                ids[0]: QueueHarness.sourceByteCount,
            ]
        )
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()

        try await harness.transcoder.waitUntilStarted(ids[0])
        try await harness.transcoder.succeed(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])
        try await harness.transcoder.succeed(ids[1])
        try await harness.waitUntilIdle()

        let snapshot = await harness.coordinator.snapshot()
        #expect(snapshot.job(id: ids[0])?.state.phase == .noBenefit)
        #expect(snapshot.job(id: ids[1])?.state.phase == .completed)
        #expect(await harness.transcoder.startedJobIDs() == ids)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Only waiting jobs reorder while ready, waiting and finished jobs remove")
    func reorderRemoveAndMutationGuards() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(ids[0])

        try await harness.coordinator.moveQueued(
            jobID: ids[3],
            before: ids[1]
        )
        try await harness.coordinator.removeJob(jobID: ids[2])

        let mutated = await harness.coordinator.snapshot()
        #expect(mutated.queuedJobIDs == [ids[3], ids[1]])
        #expect(mutated.job(id: ids[2]) == nil)

        await expectCoordinatorError(.queueMutationRequiresQueued(ids[0])) {
            try await harness.coordinator.moveQueued(
                jobID: ids[0],
                before: ids[1]
            )
        }
        await expectCoordinatorError(.activeQueueJob(ids[0])) {
            try await harness.coordinator.removeJob(jobID: ids[0])
        }

        try await harness.transcoder.succeed(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[3])
        try await harness.transcoder.succeed(ids[3])
        try await harness.transcoder.waitUntilStarted(ids[1])
        try await harness.transcoder.succeed(ids[1])
        try await harness.waitUntilIdle()

        #expect(
            await harness.transcoder.startedJobIDs()
                == [ids[0], ids[3], ids[1]]
        )
        let completedJob = try #require(
            await harness.coordinator.snapshot().job(id: ids[0])
        )
        guard case .completed(let result) = completedJob.state else {
            Issue.record("Expected a completed job")
            return
        }
        try await harness.coordinator.removeJob(jobID: ids[0])
        #expect(await harness.coordinator.snapshot().job(id: ids[0]) == nil)
        #expect(await harness.fileAccess.metadata(at: result.outputURL) != nil)
        #expect(
            await harness.fileAccess.metadata(
                at: QueueHarness.inputURL(for: ids[0])
            ) != nil
        )
    }

    @Test("A prepared video can be removed before compression")
    func readyJobCanBeRemoved() async throws {
        let harness = try await QueueHarness.make()
        let id = UUID()
        _ = try await harness.coordinator.add([
            JobQueueImport(inputURL: QueueHarness.inputURL(for: id), id: id),
        ])

        #expect(await harness.coordinator.snapshot().job(id: id)?.state == .ready)

        try await harness.coordinator.removeJob(jobID: id)

        #expect(await harness.coordinator.snapshot().job(id: id) == nil)
        #expect(await harness.transcoder.startedJobIDs().isEmpty)
    }

    @Test("Cancelled, failed and no-benefit session entries can be removed")
    func terminalSessionEntriesCanBeRemoved() async throws {
        let cancelledHarness = try await QueueHarness.make()
        let cancelledID = UUID()
        try await cancelledHarness.addAndEnqueue([cancelledID])
        await cancelledHarness.coordinator.cancel(jobID: cancelledID)
        try await cancelledHarness.coordinator.removeJob(jobID: cancelledID)
        #expect(
            await cancelledHarness.coordinator.snapshot().job(
                id: cancelledID
            ) == nil
        )

        let failedHarness = try await QueueHarness.make()
        let failedID = UUID()
        try await failedHarness.addAndEnqueue([failedID])
        await failedHarness.coordinator.startQueue()
        try await failedHarness.transcoder.waitUntilStarted(failedID)
        try await failedHarness.transcoder.fail(failedID)
        try await failedHarness.waitUntilIdle()
        try await failedHarness.coordinator.removeJob(jobID: failedID)
        #expect(
            await failedHarness.coordinator.snapshot().job(id: failedID) == nil
        )

        let noBenefitID = UUID()
        let noBenefitHarness = try await QueueHarness.make(
            candidateByteCounts: [
                noBenefitID: QueueHarness.sourceByteCount,
            ]
        )
        try await noBenefitHarness.addAndEnqueue([noBenefitID])
        await noBenefitHarness.coordinator.startQueue()
        try await noBenefitHarness.transcoder.waitUntilStarted(noBenefitID)
        try await noBenefitHarness.transcoder.succeed(noBenefitID)
        try await noBenefitHarness.waitUntilIdle()
        try await noBenefitHarness.coordinator.removeJob(jobID: noBenefitID)
        #expect(
            await noBenefitHarness.coordinator.snapshot().job(
                id: noBenefitID
            ) == nil
        )
    }

    @Test("Retrying a failed job appends one attempt to the tail")
    func failedRetryGoesToTail() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()

        try await harness.transcoder.waitUntilStarted(ids[0])
        try await harness.transcoder.fail(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])

        _ = try await harness.coordinator.retryQueued(
            jobID: ids[0],
            configuration: harness.configuration
        )
        #expect(
            await harness.coordinator.snapshot().queuedJobIDs
                == [ids[2], ids[0]]
        )

        try await harness.transcoder.succeed(ids[1])
        try await harness.transcoder.waitUntilStarted(ids[2])
        try await harness.transcoder.succeed(ids[2])
        try await harness.transcoder.waitUntilStarted(ids[0], attempt: 2)
        try await harness.transcoder.succeed(ids[0], attempt: 2)
        try await harness.waitUntilIdle()

        #expect(
            await harness.transcoder.startedJobIDs()
                == [ids[0], ids[1], ids[2], ids[0]]
        )
        #expect(await harness.transcoder.startCount(for: ids[0]) == 2)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Retrying a cancelled job appends one attempt to the tail")
    func cancelledRetryGoesToTail() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()

        try await harness.transcoder.waitUntilStarted(ids[0])
        await harness.coordinator.cancel(jobID: ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])

        _ = try await harness.coordinator.retryQueued(
            jobID: ids[0],
            configuration: harness.configuration
        )
        #expect(
            await harness.coordinator.snapshot().queuedJobIDs
                == [ids[2], ids[0]]
        )
        try await harness.transcoder.succeed(ids[1])
        try await harness.transcoder.waitUntilStarted(ids[2])
        try await harness.transcoder.succeed(ids[2])
        try await harness.transcoder.waitUntilStarted(ids[0], attempt: 2)
        try await harness.transcoder.succeed(ids[0], attempt: 2)
        try await harness.waitUntilIdle()

        #expect(
            await harness.transcoder.startedJobIDs()
                == [ids[0], ids[1], ids[2], ids[0]]
        )
        #expect(await harness.transcoder.startCount(for: ids[0]) == 2)
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Cancellation during retry preparation prevents queue admission")
    func cancelWinsRetryPreparationRace() async throws {
        let mediaInfo = try TestFixtures.mediaInfo()
        let prober = RetryPreparationProber(mediaInfo: mediaInfo)
        let harness = try await QueueHarness.make(mediaProber: prober)
        let id = UUID()

        _ = try await harness.coordinator.add([
            JobQueueImport(inputURL: QueueHarness.inputURL(for: id), id: id),
        ])
        #expect(
            await harness.coordinator.snapshot().job(id: id)?.state.phase
                == .failed
        )

        let retryTask = Task {
            try await harness.coordinator.retryQueued(
                jobID: id,
                configuration: harness.configuration
            )
        }
        try await prober.waitUntilRetryProbeStarted()
        await harness.coordinator.cancel(jobID: id)

        do {
            _ = try await retryTask.value
            Issue.record("Expected retry preparation cancellation")
        } catch is CancellationError {
            // Cancellation is the expected terminal outcome for this attempt.
        } catch {
            Issue.record("Unexpected retry error: \(error)")
        }

        let snapshot = await harness.coordinator.snapshot()
        #expect(snapshot.job(id: id)?.state.phase == .cancelled)
        #expect(snapshot.queuedJobIDs.isEmpty)
        #expect(snapshot.activeJobID == nil)
        #expect(!snapshot.isDraining)
        #expect(await harness.transcoder.startedJobIDs().isEmpty)
    }

    @Test("Same-stem jobs receive base and numeric-suffix output names")
    func sameStemOutputsAppendNumericSuffix() async throws {
        let ledger = QueueCommittedPathLedger()
        let harness = try await QueueHarness.make(
            plannerMode: .real(ledger)
        )
        let ids = [UUID(), UUID()]
        let inputs = [
            URL(fileURLWithPath: "/virtual-inputs/first/shared.mov"),
            URL(fileURLWithPath: "/virtual-inputs/second/shared.mp4"),
        ]
        _ = try await harness.coordinator.add(
            zip(ids, inputs).map {
                JobQueueImport(inputURL: $0.1, id: $0.0)
            }
        )
        for id in ids {
            _ = try await harness.coordinator.enqueue(
                jobID: id,
                configuration: harness.configuration
            )
        }

        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(ids[0])
        try await harness.transcoder.succeed(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[1])
        try await harness.transcoder.succeed(ids[1])
        try await harness.waitUntilIdle()

        let snapshot = await harness.coordinator.snapshot()
        #expect(
            snapshot.job(id: ids[0])?.completedOutputName
                == "shared-compressed.mp4"
        )
        #expect(
            snapshot.job(id: ids[1])?.completedOutputName
                == "shared-compressed-2.mp4"
        )
        #expect(await harness.transcoder.startedJobIDs() == ids)
    }

    @Test("Failing one same-stem collision does not stop the queue")
    func sameStemFailPolicyContinuesQueue() async throws {
        let ledger = QueueCommittedPathLedger()
        let harness = try await QueueHarness.make(
            plannerMode: .real(ledger)
        )
        let configuration = JobConfiguration(
            recipe: harness.configuration.recipe,
            outputPolicy: try OutputPolicy(
                directoryURL: harness.configuration.outputPolicy.directoryURL,
                conflictPolicy: .fail
            )
        )
        let ids = [UUID(), UUID(), UUID()]
        let inputs = [
            URL(fileURLWithPath: "/virtual-inputs/first/shared.mov"),
            URL(fileURLWithPath: "/virtual-inputs/second/shared.mp4"),
            URL(fileURLWithPath: "/virtual-inputs/third/unique.mov"),
        ]
        _ = try await harness.coordinator.add(
            zip(ids, inputs).map {
                JobQueueImport(inputURL: $0.1, id: $0.0)
            }
        )
        for id in ids {
            _ = try await harness.coordinator.enqueue(
                jobID: id,
                configuration: configuration
            )
        }

        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(ids[0])
        try await harness.transcoder.succeed(ids[0])
        try await harness.transcoder.waitUntilStarted(ids[2])
        try await harness.transcoder.succeed(ids[2])
        try await harness.waitUntilIdle()

        let snapshot = await harness.coordinator.snapshot()
        #expect(
            snapshot.job(id: ids[0])?.completedOutputName
                == "shared-compressed.mp4"
        )
        if let conflictedJob = snapshot.job(id: ids[1]),
           case .failed(let failure) = conflictedJob.state {
            #expect(failure.stage == .preflight)
            #expect(failure.reason == .outputConflict)
        } else {
            Issue.record("Expected only the conflicted job to fail")
        }
        #expect(snapshot.job(id: ids[2])?.state.phase == .completed)
        #expect(await harness.transcoder.startedJobIDs() == [ids[0], ids[2]])
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Concurrent add, cancel, and queue wakeups do not duplicate starts")
    func concurrentAddCancelAndStarts() async throws {
        let harness = try await QueueHarness.make()
        let anchor = UUID()
        try await harness.addAndEnqueue([anchor])
        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(anchor)

        let additions = (0..<8).map { _ in UUID() }
        let cancelled = Set(additions.enumerated().compactMap { index, id in
            index.isMultiple(of: 2) ? id : nil
        })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in additions {
                group.addTask {
                    _ = try await harness.coordinator.add([
                        JobQueueImport(
                            inputURL: QueueHarness.inputURL(for: id),
                            id: id
                        ),
                    ])
                    _ = try await harness.coordinator.enqueue(
                        jobID: id,
                        configuration: harness.configuration
                    )
                    if cancelled.contains(id) {
                        await harness.coordinator.cancel(jobID: id)
                    }
                }
            }
            try await group.waitForAll()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await harness.coordinator.startQueue()
                }
            }
        }

        let expectedQueued = await harness.coordinator.snapshot().queuedJobIDs
        try await harness.transcoder.succeed(anchor)
        for id in expectedQueued {
            try await harness.transcoder.waitUntilStarted(id)
            try await harness.transcoder.succeed(id)
        }
        try await harness.waitUntilIdle()

        let starts = await harness.transcoder.startedJobIDs()
        #expect(starts == [anchor] + expectedQueued)
        #expect(Set(starts).count == starts.count)
        #expect(cancelled.isDisjoint(with: starts))
        #expect(await harness.transcoder.maximumConcurrentCount() == 1)
    }

    @Test("Shutdown cancels the active job and every waiter before returning")
    func shutdownDrainsQueueAndRejectsNewWork() async throws {
        let harness = try await QueueHarness.make()
        let ids = [UUID(), UUID(), UUID()]
        try await harness.addAndEnqueue(ids)
        await harness.coordinator.startQueue()
        try await harness.transcoder.waitUntilStarted(ids[0])

        await harness.coordinator.shutdown()

        let snapshot = await harness.coordinator.snapshot()
        #expect(!snapshot.isDraining)
        #expect(snapshot.activeJobID == nil)
        #expect(snapshot.queuedJobIDs.isEmpty)
        #expect(snapshot.jobs.allSatisfy { $0.state.phase == .cancelled })
        #expect(await harness.transcoder.startedJobIDs() == [ids[0]])
        #expect(
            (await harness.transcoder.cancelledJobIDs()).contains(ids[0])
        )

        await harness.coordinator.startQueue()
        #expect(!(await harness.coordinator.snapshot().isDraining))
        await expectCoordinatorError(.shuttingDown) {
            _ = try await harness.coordinator.add([
                JobQueueImport(inputURL: QueueHarness.inputURL(for: UUID())),
            ])
        }
    }

    private func expectCoordinatorError(
        _ expected: CompressionCoordinatorError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected coordinator error: \(expected)")
        } catch let error as CompressionCoordinatorError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct QueueHarness: Sendable {
    static let sourceByteCount: Int64 = 4_096

    let coordinator: JobQueueCoordinator
    let transcoder: ControlledQueueTranscoder
    let fileAccess: QueueFileAccess
    let configuration: JobConfiguration

    static func make(
        mediaProber: (any MediaProbing)? = nil,
        plannerMode: QueueOutputPlannerMode = .perJob,
        candidateByteCounts: [CompressionJob.ID: Int64] = [:]
    ) async throws -> QueueHarness {
        let outputDirectory = URL(
            fileURLWithPath: "/tmp/ResizerQueueTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let committedPathLedger: QueueCommittedPathLedger?
        let outputPlanner: any OutputPlanning
        switch plannerMode {
        case .perJob:
            committedPathLedger = nil
            outputPlanner = FakeOutputPlanner { request in
                try OutputPlan(
                    request: request,
                    temporaryURL: request.policy.directoryURL
                        .appendingPathComponent(
                            "\(request.jobID.uuidString).partial.mp4"
                        ),
                    finalURL: request.policy.directoryURL
                        .appendingPathComponent(
                            "\(request.jobID.uuidString).mp4"
                        )
                )
            }
        case .real(let ledger):
            committedPathLedger = ledger
            outputPlanner = OutputPlanner(fileExists: { url in
                ledger.contains(url)
            })
        }
        let fileAccess = QueueFileAccess(
            outputDirectory: outputDirectory,
            committedPathLedger: committedPathLedger
        )
        let transcoder = ControlledQueueTranscoder(
            fileAccess: fileAccess,
            candidateByteCounts: candidateByteCounts
        )
        // This fake is used for both the input probe and the validated
        // encoded-output probe. A successful production encode explicitly
        // signals limited range, so the fake must model that contract too.
        let mediaInfo = try TestFixtures.mediaInfo(colorRange: "tv")
        let selectedMediaProber: any MediaProbing
        if let mediaProber {
            selectedMediaProber = mediaProber
        } else {
            selectedMediaProber = FakeMediaProber { _ in mediaInfo }
        }
        let configuration = JobConfiguration(
            recipe: try AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                settings: .quick(audio: .keep)
            ),
            outputPolicy: try OutputPolicy(directoryURL: outputDirectory)
        )
        let coordinator = JobQueueCoordinator(
            dependencies: CompressionCoordinatorDependencies(
                mediaProber: selectedMediaProber,
                transcoder: transcoder,
                outputPlanner: outputPlanner,
                fileAccess: fileAccess
            )
        )
        return QueueHarness(
            coordinator: coordinator,
            transcoder: transcoder,
            fileAccess: fileAccess,
            configuration: configuration
        )
    }

    static func inputURL(for id: CompressionJob.ID) -> URL {
        URL(fileURLWithPath: "/virtual-inputs/\(id.uuidString).mov")
    }

    func addAndEnqueue(_ ids: [CompressionJob.ID]) async throws {
        _ = try await coordinator.add(
            ids.map {
                JobQueueImport(inputURL: Self.inputURL(for: $0), id: $0)
            }
        )
        for id in ids {
            _ = try await coordinator.enqueue(
                jobID: id,
                configuration: configuration
            )
        }
    }

    func waitUntilIdle() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await coordinator.snapshot().isDraining {
            guard clock.now < deadline else {
                throw QueueFakeError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private extension CompressionSnapshot {
    func job(id: CompressionJob.ID) -> CompressionJob? {
        jobs.first { $0.id == id }
    }
}

private extension CompressionJob {
    var completedOutputName: String? {
        guard case .completed(let result) = state else { return nil }
        return result.outputURL.lastPathComponent
    }
}

private nonisolated enum QueueFakeError: Error, Sendable, Equatable {
    case encode
    case probe
    case attemptNotStarted
    case timeout
    case invalidFileOperation
}

private enum QueueOutputPlannerMode: Sendable {
    case perJob
    case real(QueueCommittedPathLedger)
}

private final class QueueCommittedPathLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<URL> = []

    func contains(_ url: URL) -> Bool {
        lock.withLock {
            paths.contains(url.standardizedFileURL)
        }
    }

    func insert(_ url: URL) {
        lock.withLock {
            _ = paths.insert(url.standardizedFileURL)
        }
    }
}

private actor RetryPreparationProber: MediaProbing {
    private let mediaInfo: MediaInfo
    private var sourceProbeCount = 0
    private var retryProbeStarted = false

    init(mediaInfo: MediaInfo) {
        self.mediaInfo = mediaInfo
    }

    func probe(_ sourceURL: URL) async throws -> MediaInfo {
        _ = sourceURL
        sourceProbeCount += 1
        if sourceProbeCount == 1 {
            throw QueueFakeError.probe
        }

        guard sourceProbeCount == 2 else { return mediaInfo }
        retryProbeStarted = true
        try await Task.sleep(for: .seconds(5))
        return mediaInfo
    }

    func waitUntilRetryProbeStarted() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !retryProbeStarted {
            guard clock.now < deadline else {
                throw QueueFakeError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private nonisolated struct QueueAttemptKey: Sendable, Hashable {
    let jobID: CompressionJob.ID
    let attempt: Int
}

private nonisolated enum QueueAttemptCompletion: Sendable {
    case success
    case failure
    case cancelled
}

private actor ControlledQueueTranscoder: Transcoding {
    private let fileAccess: QueueFileAccess
    private let candidateByteCounts: [CompressionJob.ID: Int64]
    private var starts: [QueueAttemptKey] = []
    private var active: Set<QueueAttemptKey> = []
    private var maximumConcurrent = 0
    private var gates: [
        QueueAttemptKey: CheckedContinuation<QueueAttemptCompletion, Never>
    ] = [:]
    private var cancellations: [CompressionJob.ID] = []

    init(
        fileAccess: QueueFileAccess,
        candidateByteCounts: [CompressionJob.ID: Int64]
    ) {
        self.fileAccess = fileAccess
        self.candidateByteCounts = candidateByteCounts
    }

    func transcode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult {
        _ = onProgress
        let attempt = starts.filter { $0.jobID == request.jobID }.count + 1
        let key = QueueAttemptKey(jobID: request.jobID, attempt: attempt)
        starts.append(key)
        active.insert(key)
        maximumConcurrent = max(maximumConcurrent, active.count)

        let completion = await withCheckedContinuation { continuation in
            gates[key] = continuation
        }
        active.remove(key)

        switch completion {
        case .failure:
            throw QueueFakeError.encode
        case .cancelled:
            throw CancellationError()
        case .success:
            let candidateByteCount = candidateByteCounts[request.jobID]
                ?? 2_048
            let metadata = FileMetadata(
                byteCount: candidateByteCount,
                isDirectory: false,
                identity: reservation.metadata.identity
            )
            await fileAccess.markEncoded(
                reservation: reservation,
                metadata: metadata
            )
            return try TranscodeResult(
                byteCount: metadata.byteCount,
                temporaryMetadata: metadata
            )
        }
    }

    func cancel(jobID: CompressionJob.ID) {
        cancellations.append(jobID)
        let keys = active.filter { $0.jobID == jobID }
        for key in keys {
            gates.removeValue(forKey: key)?.resume(returning: .cancelled)
        }
    }

    func waitUntilStarted(
        _ jobID: CompressionJob.ID,
        attempt: Int = 1
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let key = QueueAttemptKey(jobID: jobID, attempt: attempt)
        while !starts.contains(key) {
            guard clock.now < deadline else {
                throw QueueFakeError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func succeed(
        _ jobID: CompressionJob.ID,
        attempt: Int = 1
    ) throws {
        let key = QueueAttemptKey(jobID: jobID, attempt: attempt)
        guard let continuation = gates.removeValue(forKey: key) else {
            throw QueueFakeError.attemptNotStarted
        }
        continuation.resume(returning: .success)
    }

    func fail(
        _ jobID: CompressionJob.ID,
        attempt: Int = 1
    ) throws {
        let key = QueueAttemptKey(jobID: jobID, attempt: attempt)
        guard let continuation = gates.removeValue(forKey: key) else {
            throw QueueFakeError.attemptNotStarted
        }
        continuation.resume(returning: .failure)
    }

    func startedJobIDs() -> [CompressionJob.ID] {
        starts.map(\.jobID)
    }

    func startCount(for jobID: CompressionJob.ID) -> Int {
        starts.count { $0.jobID == jobID }
    }

    func maximumConcurrentCount() -> Int {
        maximumConcurrent
    }

    func cancelledJobIDs() -> [CompressionJob.ID] {
        cancellations
    }
}

private actor QueueFileAccess: FileAccessing {
    private let outputDirectory: URL
    private let committedPathLedger: QueueCommittedPathLedger?
    private var nextInode: UInt64 = 1
    private var encodedByTemporaryURL: [URL: FileMetadata] = [:]
    private var committedByFinalURL: [URL: FileMetadata] = [:]

    init(
        outputDirectory: URL,
        committedPathLedger: QueueCommittedPathLedger? = nil
    ) {
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.committedPathLedger = committedPathLedger
    }

    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        _ = selectedURLs
        return try await operation()
    }

    func metadata(at url: URL) -> FileMetadata? {
        let normalized = url.standardizedFileURL
        if normalized == outputDirectory {
            return FileMetadata(
                byteCount: 0,
                isDirectory: true,
                identity: FileIdentity(device: 7, inode: 1)
            )
        }
        if let metadata = encodedByTemporaryURL[normalized]
            ?? committedByFinalURL[normalized] {
            return metadata
        }
        if normalized.deletingLastPathComponent() != outputDirectory,
           ["mov", "mp4"].contains(normalized.pathExtension.lowercased()) {
            return FileMetadata(
                byteCount: QueueHarness.sourceByteCount,
                isDirectory: false,
                identity: FileIdentity(device: 7, inode: 2)
            )
        }
        return nil
    }

    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) throws -> TemporaryOutputReservation {
        guard encodedByTemporaryURL[plan.temporaryURL.standardizedFileURL]
            == nil else {
            throw QueueFakeError.invalidFileOperation
        }
        nextInode += 1
        return try TemporaryOutputReservation(
            plan: plan,
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: FileIdentity(device: 7, inode: nextInode)
            )
        )
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) throws {
        let temporaryURL = reservation.temporaryURL.standardizedFileURL
        let finalURL = plan.finalURL.standardizedFileURL
        guard committedByFinalURL[finalURL] == nil,
              encodedByTemporaryURL[temporaryURL]
                == expectedTemporaryMetadata else {
            throw QueueFakeError.invalidFileOperation
        }
        committedByFinalURL[finalURL] = expectedTemporaryMetadata
        encodedByTemporaryURL.removeValue(forKey: temporaryURL)
        committedPathLedger?.insert(finalURL)
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) {
        _ = plan
        _ = expectedTemporaryMetadata
        encodedByTemporaryURL.removeValue(
            forKey: reservation.temporaryURL.standardizedFileURL
        )
    }

    func markEncoded(
        reservation: TemporaryOutputReservation,
        metadata: FileMetadata
    ) {
        encodedByTemporaryURL[
            reservation.temporaryURL.standardizedFileURL
        ] = metadata
    }
}
