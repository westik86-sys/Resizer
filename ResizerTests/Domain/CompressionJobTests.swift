import Foundation
import Testing
@testable import Resizer

@Suite("CompressionJob invariants")
struct CompressionJobTests {
    @Test("Jobs accept only local file inputs")
    func localInputOnly() {
        #expect(throws: CompressionJobValidationError.invalidInputURL) {
            _ = try CompressionJob(
                inputURL: URL(string: "https://example.com/source.mov")!
            )
        }
    }

    @Test("Job retains identity and immutable input across the lifecycle")
    func lifecyclePreservesIdentity() throws {
        let id = UUID()
        let inputURL = URL(fileURLWithPath: "/tmp/source.mov")
        var job = try CompressionJob(id: id, inputURL: inputURL)

        try job.transition(to: .probing)
        try job.recordMediaInfo(try TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.updateProgress(TestFixtures.progress())
        try job.transition(to: .finishing(.validating))
        try job.transition(to: .finishing(.committing))
        try job.transition(to: .completed(try TestFixtures.result()))

        #expect(job.id == id)
        #expect(job.inputURL == inputURL)
        #expect(job.state.phase == .completed)
    }

    @Test("Ready requires probed media")
    func readyRequiresMediaInfo() throws {
        var job = try CompressionJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        try job.transition(to: .probing)

        do {
            try job.transition(to: .ready)
            Issue.record("Expected missingMediaInfo")
        } catch let error as CompressionJobMutationError {
            #expect(error == .missingMediaInfo)
        }
        #expect(job.state.phase == .probing)
    }

    @Test("Queueing requires a typed configuration")
    func queuedRequiresConfiguration() throws {
        var job = try CompressionJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(try TestFixtures.mediaInfo())
        try job.transition(to: .ready)

        do {
            try job.transition(to: .queued)
            Issue.record("Expected missingConfiguration")
        } catch let error as CompressionJobMutationError {
            #expect(error == .missingConfiguration)
        }
        #expect(job.state.phase == .ready)
    }

    @Test("Progress updates do not create lifecycle self-transitions")
    func progressUpdatesOnlyRunningOrCancelling() throws {
        var draft = try CompressionJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        do {
            try draft.updateProgress(TestFixtures.progress())
            Issue.record("Expected operationRequires running")
        } catch let error as CompressionJobMutationError {
            #expect(error == .operationRequires(.running))
        }

        var running = try makeRunningJob()
        let progress = try TestFixtures.progress(processedMicroseconds: 7_500_000)
        try running.updateProgress(progress)
        #expect(running.state == .running(progress: progress))

        try running.transition(to: .cancelling(lastProgress: progress))
        let laterProgress = try TestFixtures.progress(processedMicroseconds: 8_000_000)
        try running.updateProgress(laterProgress)
        #expect(running.state == .cancelling(lastProgress: laterProgress))
    }

    @Test("Completion cannot publish the immutable input as its output")
    func completionRejectsInputURL() throws {
        var job = try makeRunningJob()
        try job.transition(to: .finishing(.validating))
        try job.transition(to: .finishing(.committing))
        let unsafeResult = try CompressionResult(
            outputURL: job.inputURL,
            outputByteCount: 1,
            elapsed: .seconds(1)
        )

        do {
            try job.transition(to: .completed(unsafeResult))
            Issue.record("Expected input/output alias rejection")
        } catch let error as CompressionJobMutationError {
            #expect(error == .outputAliasesInput)
        }
        #expect(job.state == .finishing(.committing))
    }

    @Test("Retrying probe discards stale probe data")
    func probeRetryClearsMediaInfo() throws {
        var job = try CompressionJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(try TestFixtures.mediaInfo())
        try job.transition(
            to: .failed(TestFixtures.failure(stage: .probe))
        )
        try job.transition(to: .probing)

        #expect(job.mediaInfo == nil)
        #expect(job.configuration == nil)
        #expect(throws: CompressionJobMutationError.missingMediaInfo) {
            try job.transition(to: .ready)
        }
    }

    private func makeRunningJob() throws -> CompressionJob {
        var job = try CompressionJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov")
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(try TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        try job.configure(TestFixtures.configuration())
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        return job
    }
}
