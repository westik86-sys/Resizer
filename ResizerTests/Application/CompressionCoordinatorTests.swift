import Foundation
import Testing
@testable import Resizer

@Suite("CompressionCoordinator")
struct CompressionCoordinatorTests {
    @Test("Coordinator publishes ordered immutable value snapshots")
    func orderedSnapshots() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try TestFixtures.dependencies()
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/first.mov"),
            id: firstID
        )
        _ = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/second.mov"),
            id: secondID
        )

        let beforeTransition = await coordinator.snapshot()
        _ = try await coordinator.transition(jobID: firstID, to: .probing)
        let afterTransition = await coordinator.snapshot()

        #expect(beforeTransition.jobs.map(\.id) == [firstID, secondID])
        #expect(beforeTransition.jobs.first == first)
        #expect(beforeTransition.jobs.first?.state == .draft)
        #expect(afterTransition.jobs.first?.state == .probing)
    }

    @Test("Duplicate IDs and unknown jobs are rejected")
    func identityErrors() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try TestFixtures.dependencies()
        )
        let job = try CompressionJob(
            id: UUID(),
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        try await coordinator.register(job)

        do {
            try await coordinator.register(job)
            Issue.record("Expected duplicate job rejection")
        } catch let error as CompressionCoordinatorError {
            #expect(error == .duplicateJob(job.id))
        }

        let missingID = UUID()
        do {
            _ = try await coordinator.transition(jobID: missingID, to: .probing)
            Issue.record("Expected missing job rejection")
        } catch let error as CompressionCoordinatorError {
            #expect(error == .jobNotFound(missingID))
        }
    }

    @Test("Coordinator permits only one active job")
    func singleActiveJob() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try TestFixtures.dependencies()
        )
        let firstID = UUID()
        let secondID = UUID()
        try await enqueue(firstID, on: coordinator)
        try await enqueue(secondID, on: coordinator)

        _ = try await coordinator.transition(
            jobID: firstID,
            to: .running(progress: nil)
        )

        do {
            _ = try await coordinator.transition(
                jobID: secondID,
                to: .running(progress: nil)
            )
            Issue.record("Expected active job rejection")
        } catch let error as CompressionCoordinatorError {
            #expect(error == .activeJobExists(firstID))
        }
        #expect(await coordinator.job(id: secondID)?.state == .queued)
    }

    @Test("MainActor feature model receives coordinator snapshots")
    @MainActor
    func featureModelUsesInjectedCoordinator() async throws {
        let composition = try AppComposition.preview()
        let job = try await composition.compressionFeatureModel.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/preview.mov")
        )

        #expect(composition.compressionFeatureModel.jobs.map(\.id) == [job.id])
        #expect(composition.compressionFeatureModel.jobs.first?.state == .draft)
    }

    @Test("Snapshot stream sends current state and bounded live updates")
    func snapshotStream() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try TestFixtures.dependencies()
        )
        let stream = await coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .empty)

        let job = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/live.mov")
        )
        #expect(await iterator.next()?.jobs == [job])

        _ = try await coordinator.transition(jobID: job.id, to: .probing)
        let probing = try #require(await iterator.next())
        #expect(probing.jobs.first?.state == .probing)
    }

    @Test("An idle ready job can be abandoned to release the active slot")
    func cancelIdleReadyJob() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try TestFixtures.dependencies()
        )
        let first = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/first.mov")
        )
        _ = try await coordinator.transition(
            jobID: first.id,
            to: .probing
        )
        _ = try await coordinator.recordMediaInfo(
            TestFixtures.mediaInfo(),
            for: first.id
        )
        _ = try await coordinator.transition(
            jobID: first.id,
            to: .ready
        )

        await coordinator.cancel(jobID: first.id)

        #expect(await coordinator.job(id: first.id)?.state == .cancelled)
        let second = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/second.mp4")
        )
        #expect(second.state == .draft)
    }

    @Test("Preparation validates actual capabilities before publishing ready")
    func preparationValidatesCapabilities() async throws {
        let recorder = CapabilityValidationRecorder()
        let mediaInfo = try TestFixtures.mediaInfo()
        let coordinator = CompressionCoordinator(
            dependencies: try dependencies { observedMedia, recipe in
                await recorder.record(
                    mediaInfo: observedMedia,
                    recipe: recipe
                )
            }
        )
        let job = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/capabilities.mov")
        )

        let ready = try await coordinator.prepare(jobID: job.id)
        let expectedRecipe = try CompressionRecipe(preset: .default)

        #expect(ready.state == .ready)
        #expect(await recorder.callCount == 1)
        #expect(await recorder.mediaInfo == mediaInfo)
        #expect(await recorder.recipe == expectedRecipe)
    }

    @Test("Unavailable bundled capabilities never publish ready settings")
    func unavailableCapabilitiesFailPreparation() async throws {
        let coordinator = CompressionCoordinator(
            dependencies: try dependencies { _, _ in
                throw FFmpegPreflightError.unavailableCapability(
                    category: .encoder,
                    name: "h264_videotoolbox"
                )
            }
        )
        let job = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/unavailable.mov")
        )

        do {
            _ = try await coordinator.prepare(jobID: job.id)
            Issue.record("Expected capability validation to fail")
        } catch let failure as TranscodeFailure {
            #expect(failure.stage == .probe)
            #expect(failure.reason == .serviceUnavailable)
        }

        let stored = try #require(await coordinator.job(id: job.id))
        guard case .failed(let failure) = stored.state else {
            Issue.record("Expected failed state, got \(stored.state)")
            return
        }
        #expect(failure.reason == .serviceUnavailable)
        #expect(stored.mediaInfo == nil)
    }

    @Test("A cancel at the end of capability validation wins ready")
    func latePreparationCancellation() async throws {
        let jobID = UUID()
        let relay = CoordinatorCancellationRelay()
        let coordinator = CompressionCoordinator(
            dependencies: try dependencies { _, _ in
                await relay.cancel(jobID: jobID)
            }
        )
        await relay.install(coordinator)
        _ = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/late-cancel.mov"),
            id: jobID
        )

        do {
            _ = try await coordinator.prepare(jobID: jobID)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // The intent recorded after capability discovery must win.
        }

        #expect(await coordinator.job(id: jobID)?.state == .cancelled)
    }

    private func enqueue(
        _ id: CompressionJob.ID,
        on coordinator: CompressionCoordinator
    ) async throws {
        _ = try await coordinator.createJob(
            inputURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).mov"),
            id: id
        )
        _ = try await coordinator.transition(jobID: id, to: .probing)
        _ = try await coordinator.recordMediaInfo(
            try TestFixtures.mediaInfo(),
            for: id
        )
        _ = try await coordinator.transition(jobID: id, to: .ready)
        _ = try await coordinator.configure(
            try TestFixtures.configuration(),
            for: id
        )
        _ = try await coordinator.transition(jobID: id, to: .queued)
    }

    private func dependencies(
        capabilityHandler: @escaping FakeTranscoder.CapabilityHandler
    ) throws -> CompressionCoordinatorDependencies {
        let base = try TestFixtures.dependencies()
        return CompressionCoordinatorDependencies(
            mediaProber: base.mediaProber,
            transcoder: FakeTranscoder(
                capabilityHandler: capabilityHandler,
                handler: { _, _ in
                    try TranscodeResult(
                        byteCount: 1,
                        temporaryMetadata: FileMetadata(
                            byteCount: 1,
                            isDirectory: false,
                            identity: FileIdentity(device: 1, inode: 1)
                        )
                    )
                },
                cancellationHandler: { _ in }
            ),
            outputPlanner: base.outputPlanner,
            fileAccess: base.fileAccess
        )
    }
}

private actor CapabilityValidationRecorder {
    private(set) var callCount = 0
    private(set) var mediaInfo: MediaInfo?
    private(set) var recipe: CompressionRecipe?

    func record(
        mediaInfo: MediaInfo,
        recipe: CompressionRecipe
    ) {
        callCount += 1
        self.mediaInfo = mediaInfo
        self.recipe = recipe
    }
}

private actor CoordinatorCancellationRelay {
    private var coordinator: CompressionCoordinator?

    func install(_ coordinator: CompressionCoordinator) {
        self.coordinator = coordinator
    }

    func cancel(jobID: CompressionJob.ID) async {
        await coordinator?.cancel(jobID: jobID)
    }
}
