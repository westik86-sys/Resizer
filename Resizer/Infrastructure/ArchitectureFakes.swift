import Foundation

#if DEBUG
nonisolated struct FakeMediaProber: MediaProbing {
    let handler: @Sendable (URL) async throws -> MediaInfo

    func probe(_ sourceURL: URL) async throws -> MediaInfo {
        try await handler(sourceURL)
    }
}

nonisolated struct FakeTranscoder: Transcoding {
    typealias ProgressHandler = @Sendable (TranscodeProgress) async -> Void
    typealias Handler = @Sendable (
        TranscodeRequest,
        ProgressHandler
    ) async throws -> TranscodeResult

    let handler: Handler
    let cancellationHandler: @Sendable (CompressionJob.ID) async -> Void

    func transcode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping ProgressHandler
    ) async throws -> TranscodeResult {
        _ = reservation
        return try await handler(request, onProgress)
    }

    func cancel(jobID: CompressionJob.ID) async {
        await cancellationHandler(jobID)
    }
}

nonisolated struct FakeCommandBuilder: CommandBuilding {
    let handler: @Sendable (TranscodeCommandRequest) async throws -> [String]

    func arguments(for request: TranscodeCommandRequest) async throws -> [String] {
        try await handler(request)
    }
}

nonisolated struct FakeOutputPlanner: OutputPlanning {
    let handler: @Sendable (OutputPlanningRequest) async throws -> OutputPlan

    func planOutput(for request: OutputPlanningRequest) async throws -> OutputPlan {
        try await handler(request)
    }
}

nonisolated struct PassthroughFileAccess: FileAccessing {
    let metadataProvider: @Sendable (URL) async throws -> FileMetadata?
    let commitHandler: @Sendable (OutputPlan) async throws -> Void
    let cleanupHandler: @Sendable (URL) async throws -> Void

    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        _ = selectedURLs
        return try await operation()
    }

    func metadata(at url: URL) async throws -> FileMetadata? {
        try await metadataProvider(url)
    }

    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) async throws -> TemporaryOutputReservation {
        try TemporaryOutputReservation(
            plan: plan,
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: FileIdentity(device: 1, inode: 1)
            )
        )
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        _ = reservation
        _ = expectedTemporaryMetadata
        try await commitHandler(plan)
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        _ = reservation
        _ = expectedTemporaryMetadata
        try await cleanupHandler(plan.temporaryURL)
    }
}

nonisolated struct FakeProcessRunner: ProcessRunning {
    let startHandler: @Sendable (
        ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error>
    let cancellationHandler: @Sendable (ProcessExecutionID) async -> Void

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        try await startHandler(request)
    }

    func cancel(executionID: ProcessExecutionID) async {
        await cancellationHandler(executionID)
    }
}
#endif
