import Foundation
import Testing
@testable import Resizer

@Suite("Compression feature model", .serialized)
@MainActor
struct CompressionFeatureModelTests {
    @Test("Import accepts one MOV or MP4 and prepares it without encoding")
    func importPreparesSingleVideo() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()

        await model.importVideo(
            URL(fileURLWithPath: "/tmp/Camera.MOV")
        )

        let calls = await coordinator.recordedCalls()
        #expect(calls.createdInputs == [
            URL(fileURLWithPath: "/tmp/Camera.MOV"),
        ])
        #expect(calls.prepareCount == 1)
        #expect(calls.startCount == 0)
        #expect(model.currentJob?.state == .ready)
        #expect(model.outputDirectoryURL == nil)
        guard case .ready(let job) = model.screenState else {
            Issue.record("Expected ready presentation state")
            return
        }
        #expect(job.mediaInfo == (try TestFixtures.mediaInfo()))
    }

    @Test("Ready input is abandoned before replacement; active work stays blocked")
    func safeSingleInputReplacement() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()

        await model.importVideo(
            URL(fileURLWithPath: "/tmp/not-a-video.avi")
        )
        guard case .validationError = model.screenState else {
            Issue.record("Expected an import validation error")
            return
        }
        #expect((await coordinator.recordedCalls()).createdInputs.isEmpty)

        model.dismissValidationError()
        await model.importVideo(URL(fileURLWithPath: "/tmp/one.mp4"))
        let firstJobID = try #require(model.currentJobID)
        await model.importVideo(URL(fileURLWithPath: "/tmp/two.mov"))

        let replacementCalls = await coordinator.recordedCalls()
        #expect(replacementCalls.createdInputs.count == 2)
        #expect(replacementCalls.prepareCount == 2)
        #expect(replacementCalls.cancelCount == 1)
        #expect(model.currentJob?.inputURL == URL(fileURLWithPath: "/tmp/two.mov"))
        #expect(model.currentJob?.state == .ready)
        #expect(
            model.snapshot.jobs.first { $0.id == firstJobID }?.state
                == .cancelled
        )
        #expect(model.snapshot.jobs.filter(\.state.isActive).count == 1)

        let secondJobID = try #require(model.currentJobID)
        try await coordinator.replaceWithRunningJob(jobID: secondJobID)
        #expect(await eventually { model.canCancel })
        await model.importVideo(URL(fileURLWithPath: "/tmp/three.mp4"))

        #expect((await coordinator.recordedCalls()).createdInputs.count == 2)
        guard case .validationError(let message) = model.screenState else {
            Issue.record("Expected active-job validation error")
            return
        }
        #expect(message.contains("current operation"))
    }

    @Test("A replacement registration failure never leaves importing stuck")
    func replacementRegistrationFailure() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/first.mp4"))
        let firstJobID = try #require(model.currentJobID)
        await coordinator.failNextCreate()

        await model.importVideo(URL(fileURLWithPath: "/tmp/second.mov"))

        guard case .validationError(let message) = model.screenState else {
            Issue.record("Expected a registration validation error")
            return
        }
        #expect(message.contains("could not be prepared"))
        #expect(model.currentJobID == firstJobID)
        #expect(model.currentJob?.state == .cancelled)
    }

    @Test("Start requires an explicit folder and sends only typed settings")
    func startUsesTypedConfiguration() async throws {
        let coordinator = FeatureCoordinatorFake()
        let revealer = OutputRevealerSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            outputRevealer: revealer
        )
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))

        #expect(!model.canStart)
        await model.start()
        guard case .validationError = model.screenState else {
            Issue.record("Expected output-folder validation")
            return
        }

        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        model.applyPreset(.smallFile)
        #expect(model.canStart)

        await model.start(
            filenameSuffix: "-web",
            conflictPolicy: .fail
        )

        let calls = await coordinator.recordedCalls()
        #expect(calls.startCount == 1)
        #expect(calls.lastConfiguration?.recipe == (
            try CompressionRecipe(preset: .smallFile)
        ))
        #expect(
            calls.lastConfiguration?.outputPolicy.directoryURL
                == URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        #expect(calls.lastConfiguration?.outputPolicy.filenameSuffix == "-web")
        #expect(calls.lastConfiguration?.outputPolicy.conflictPolicy == .fail)
        guard case .success = model.screenState else {
            Issue.record("Expected success presentation")
            return
        }

        model.revealResultInFinder()
        #expect(
            revealer.revealedURLs
                == [URL(fileURLWithPath: "/tmp/export/result.mp4")]
        )
    }

    @Test("Probe retry repeats preparation without requiring output settings")
    func probeRetryRoutesToPrepare() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mov"))
        let jobID = try #require(model.currentJobID)

        try await coordinator.replaceWithProbeFailure(jobID: jobID)
        #expect(await eventually {
            guard case .failure(_, .transcode(let failure)) = model.screenState
            else { return false }
            return failure.stage == .probe
        })
        #expect(model.outputDirectoryURL == nil)
        #expect(model.canRetry)

        await model.retry()

        let calls = await coordinator.recordedCalls()
        #expect(calls.prepareCount == 2)
        #expect(calls.retryCount == 0)
        #expect(model.currentJob?.state == .ready)
    }

    @Test("Encode retry reuses the job and copies only bounded diagnostics")
    func encodeRetryAndDiagnostics() async throws {
        let coordinator = FeatureCoordinatorFake()
        let copier = DiagnosticCopierSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            diagnosticCopier: copier
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))
        let jobID = try #require(model.currentJobID)
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
        model.copyDiagnostics()
        #expect(copier.copiedTexts == [diagnostic.text])

        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/retry", isDirectory: true)
        )
        await model.retry(filenameSuffix: "-retry")

        let calls = await coordinator.recordedCalls()
        #expect(calls.retryCount == 1)
        #expect(calls.prepareCount == 1)
        #expect(calls.lastConfiguration?.outputPolicy.filenameSuffix == "-retry")
        #expect(model.currentJob?.id == jobID)
        guard case .success = model.screenState else {
            Issue.record("Expected retry success")
            return
        }
    }

    @Test("Cancel routes to the coordinator and presents cancellation")
    func cancellation() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))
        let jobID = try #require(model.currentJobID)

        try await coordinator.replaceWithRunningJob(jobID: jobID)
        #expect(await eventually { model.canCancel })
        await model.cancel()

        #expect((await coordinator.recordedCalls()).cancelCount == 1)
        guard case .failure(let job, .cancelled) = model.screenState else {
            Issue.record("Expected cancelled presentation")
            return
        }
        #expect(job.id == jobID)
    }

    @Test("ETA appears only after three stable, mature speed samples")
    func conservativeETA() async throws {
        let coordinator = FeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))
        let jobID = try #require(model.currentJobID)
        try await coordinator.replaceWithRunningJob(jobID: jobID)
        #expect(await eventually { model.canCancel })

        try await coordinator.sendProgress(
            jobID: jobID,
            processedMicroseconds: 3_000_000,
            totalMicroseconds: 20_000_000,
            speed: 2
        )
        #expect(await eventually {
            model.currentProgressMicroseconds == 3_000_000
        })
        #expect(model.estimatedRemainingSeconds == nil)

        try await coordinator.sendProgress(
            jobID: jobID,
            processedMicroseconds: 4_000_000,
            totalMicroseconds: 20_000_000,
            speed: 2.1
        )
        #expect(await eventually {
            model.currentProgressMicroseconds == 4_000_000
        })
        #expect(model.estimatedRemainingSeconds == nil)

        try await coordinator.sendProgress(
            jobID: jobID,
            processedMicroseconds: 5_000_000,
            totalMicroseconds: 20_000_000,
            speed: 1.9
        )
        #expect(await eventually {
            model.currentProgressMicroseconds == 5_000_000
        })
        #expect(model.estimatedRemainingSeconds == 7.5)

        try await coordinator.sendProgress(
            jobID: jobID,
            processedMicroseconds: 6_000_000,
            totalMicroseconds: 20_000_000,
            speed: 0.5
        )
        #expect(await eventually {
            model.currentProgressMicroseconds == 6_000_000
        })
        #expect(model.estimatedRemainingSeconds == nil)
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
    var currentProgressMicroseconds: Int64? {
        guard let currentJob,
              case .running(let progress) = currentJob.state else {
            return nil
        }
        return progress?.processedMicroseconds
    }
}

private extension JobState {
    var isActive: Bool {
        switch self {
        case .draft, .probing, .ready, .queued, .running, .finishing,
             .cancelling:
            true
        case .cancelled, .completed, .failed:
            false
        }
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

private actor FeatureCoordinatorFake: CompressionCoordinating {
    nonisolated struct Calls: Sendable {
        var createdInputs: [URL] = []
        var prepareCount = 0
        var startCount = 0
        var retryCount = 0
        var cancelCount = 0
        var lastConfiguration: JobConfiguration?
    }

    private var calls = Calls()
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []
    private var continuations: [
        UUID: AsyncStream<CompressionSnapshot>.Continuation
    ] = [:]
    private var hasSubscriber = false
    private var shouldFailNextCreate = false
    private var subscriberWaiters: [CheckedContinuation<Void, Never>] = []

    func createJob(
        inputURL: URL,
        id: CompressionJob.ID,
        createdAt: Date
    ) throws -> CompressionJob {
        if shouldFailNextCreate {
            shouldFailNextCreate = false
            throw CompressionCoordinatorError.activeJobExists(id)
        }
        let job = try CompressionJob(
            id: id,
            inputURL: inputURL,
            createdAt: createdAt
        )
        jobsByID[id] = job
        jobOrder.append(id)
        calls.createdInputs.append(inputURL)
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
        return job
    }

    func startPrepared(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        calls.startCount += 1
        calls.lastConfiguration = configuration
        return try complete(jobID: jobID, configuration: configuration)
    }

    func retry(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        calls.retryCount += 1
        calls.lastConfiguration = configuration
        var job = try requireJob(jobID)
        try job.transition(to: .ready)
        jobsByID[jobID] = job
        return try complete(jobID: jobID, configuration: configuration)
    }

    func cancel(jobID: CompressionJob.ID) async {
        calls.cancelCount += 1
        guard var job = jobsByID[jobID] else { return }
        do {
            switch job.state {
            case .running(let progress):
                try job.transition(to: .cancelling(lastProgress: progress))
                jobsByID[jobID] = job
                publish()
                try job.transition(to: .cancelled)
            case .probing, .queued, .ready:
                try job.transition(to: .cancelled)
            case .draft, .finishing, .cancelling, .cancelled, .completed,
                 .failed:
                return
            }
            jobsByID[jobID] = job
            publish()
        } catch {
            Issue.record("Fake cancellation transition failed: \(error)")
        }
    }

    func snapshot() -> CompressionSnapshot {
        CompressionSnapshot(
            jobs: jobOrder.compactMap { jobsByID[$0] }
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
        pair.continuation.yield(snapshot())
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

    func failNextCreate() {
        shouldFailNextCreate = true
    }

    func replaceWithProbeFailure(
        jobID: CompressionJob.ID
    ) throws {
        let oldJob = try requireJob(jobID)
        var job = try CompressionJob(
            id: jobID,
            inputURL: oldJob.inputURL,
            createdAt: oldJob.createdAt
        )
        try job.transition(to: .probing)
        try job.transition(
            to: .failed(TestFixtures.failure(stage: .probe))
        )
        jobsByID[jobID] = job
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
        publish()
    }

    func replaceWithRunningJob(jobID: CompressionJob.ID) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        jobsByID[jobID] = job
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

    private func complete(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) throws -> CompressionJob {
        var job = try requireJob(jobID)
        try job.configure(configuration)
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(to: .finishing(.validating))
        try job.transition(to: .finishing(.committing))
        let result = try CompressionResult(
            outputURL: configuration.outputPolicy.directoryURL
                .appendingPathComponent("result.mp4"),
            outputByteCount: 1_024,
            elapsed: .seconds(2)
        )
        try job.transition(to: .completed(result))
        jobsByID[jobID] = job
        publish()
        return job
    }

    private func makeReadyJob(
        jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        let oldJob = try requireJob(jobID)
        var job = try CompressionJob(
            id: jobID,
            inputURL: oldJob.inputURL,
            createdAt: oldJob.createdAt
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        return job
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
        let value = snapshot()
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
