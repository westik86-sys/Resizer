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
}
