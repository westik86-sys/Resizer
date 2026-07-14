import Foundation

nonisolated protocol MediaProbing: Sendable {
    func probe(_ sourceURL: URL) async throws -> MediaInfo
}

nonisolated protocol Transcoding: Sendable {
    /// Validates the complete command and the bundled encoder capabilities
    /// before the job enters its running state.
    func preflight(_ request: TranscodeRequest) async throws

    func transcode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult

    func cancel(jobID: CompressionJob.ID) async
}

extension Transcoding {
    func preflight(_ request: TranscodeRequest) async throws {
        _ = request
    }

}

nonisolated protocol ProcessRunning: Sendable {
    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error>

    /// Requests teardown for an execution whose `start` call has returned.
    /// Unknown and already-completed IDs are no-ops. Cancelling the caller task
    /// stops its wait while actor-owned teardown continues.
    func cancel(executionID: ProcessExecutionID) async
}

nonisolated protocol CommandBuilding: Sendable {
    func arguments(for request: TranscodeCommandRequest) async throws -> [String]
}

nonisolated protocol OutputPlanning: Sendable {
    func planOutput(for request: OutputPlanningRequest) async throws -> OutputPlan
}

nonisolated protocol FileAccessing: Sendable {
    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result

    func metadata(at url: URL) async throws -> FileMetadata?
    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) async throws -> TemporaryOutputReservation
    func commitWithoutReplacing(
        _ plan: OutputPlan,
        expectedTemporaryMetadata: FileMetadata
    ) async throws
    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws
}

nonisolated struct TranscodeRequest: Sendable, Equatable {
    let jobID: CompressionJob.ID
    let inputURL: URL
    let temporaryOutputURL: URL
    let mediaInfo: MediaInfo
    let recipe: CompressionRecipe

    init(
        outputPlan: OutputPlan,
        mediaInfo: MediaInfo,
        recipe: CompressionRecipe
    ) {
        jobID = outputPlan.jobID
        inputURL = outputPlan.inputURL
        temporaryOutputURL = outputPlan.temporaryURL
        self.mediaInfo = mediaInfo
        self.recipe = recipe
    }
}

nonisolated struct TranscodeResult: Sendable, Equatable {
    let byteCount: Int64
    /// The exact file produced by the transcoder. The workflow carries this
    /// seal through validation, cleanup, and the no-replace commit.
    let temporaryMetadata: FileMetadata

    init(
        byteCount: Int64,
        temporaryMetadata: FileMetadata
    ) throws {
        guard byteCount > 0,
              !temporaryMetadata.isDirectory,
              temporaryMetadata.byteCount == byteCount,
              temporaryMetadata.identity != nil else {
            throw TranscodeContractValidationError.invalidResult
        }
        self.byteCount = byteCount
        self.temporaryMetadata = temporaryMetadata
    }
}

nonisolated struct TranscodeCommandRequest: Sendable, Equatable {
    let jobID: CompressionJob.ID
    let inputURL: URL
    let temporaryOutputURL: URL
    let mediaInfo: MediaInfo
    let recipe: CompressionRecipe

    init(transcodeRequest: TranscodeRequest) {
        jobID = transcodeRequest.jobID
        inputURL = transcodeRequest.inputURL
        temporaryOutputURL = transcodeRequest.temporaryOutputURL
        mediaInfo = transcodeRequest.mediaInfo
        recipe = transcodeRequest.recipe
    }
}

nonisolated enum TranscodeContractValidationError: Error, Sendable, Equatable {
    case invalidResult
}

nonisolated struct OutputPlanningRequest: Sendable, Equatable {
    let jobID: CompressionJob.ID
    let inputURL: URL
    let policy: OutputPolicy
}

nonisolated struct OutputPlan: Sendable, Equatable {
    let jobID: CompressionJob.ID
    let inputURL: URL
    let temporaryURL: URL
    let finalURL: URL

    init(
        request: OutputPlanningRequest,
        temporaryURL: URL,
        finalURL: URL
    ) throws {
        guard request.inputURL.isFileURL,
              temporaryURL.isFileURL,
              finalURL.isFileURL else {
            throw OutputPlanValidationError.invalidPlan
        }

        let input = request.inputURL.standardizedFileURL
        let outputDirectory = request.policy.directoryURL.standardizedFileURL
        let temporary = temporaryURL.standardizedFileURL
        let final = finalURL.standardizedFileURL
        let temporaryName = temporary.lastPathComponent.lowercased()
        let jobToken = request.jobID.uuidString.lowercased()

        guard input != temporary,
              input != final,
              temporary != final,
              temporary.deletingLastPathComponent() == outputDirectory,
              final.deletingLastPathComponent() == outputDirectory,
              temporary.pathExtension.lowercased() == "mp4",
              final.pathExtension.lowercased() == "mp4",
              temporaryName.contains(jobToken),
              temporaryName.hasSuffix(".partial.mp4") else {
            throw OutputPlanValidationError.invalidPlan
        }

        jobID = request.jobID
        inputURL = request.inputURL
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
    }
}

/// An empty regular file created atomically for exactly one output plan.
/// FFmpeg receives this inode through an inherited descriptor rather than
/// reopening a pathname, so later cleanup can always require an identity seal.
nonisolated struct TemporaryOutputReservation: Sendable, Equatable {
    let jobID: CompressionJob.ID
    let temporaryURL: URL
    let metadata: FileMetadata

    init(plan: OutputPlan, metadata: FileMetadata) throws {
        guard metadata.byteCount == 0,
              !metadata.isDirectory,
              metadata.identity != nil else {
            throw TemporaryOutputReservationValidationError
                .invalidReservation
        }
        jobID = plan.jobID
        temporaryURL = plan.temporaryURL.standardizedFileURL
        self.metadata = metadata
    }
}

nonisolated enum TemporaryOutputReservationValidationError:
    Error,
    Sendable,
    Equatable
{
    case invalidReservation
}

nonisolated enum OutputPlanValidationError: Error, Sendable, Equatable {
    case invalidPlan
}

nonisolated struct FileMetadata: Sendable, Equatable {
    let byteCount: Int64
    let isDirectory: Bool
    let identity: FileIdentity?
    let modificationTimeNanoseconds: Int64?
    let statusChangeTimeNanoseconds: Int64?

    init(
        byteCount: Int64,
        isDirectory: Bool,
        identity: FileIdentity? = nil,
        modificationTimeNanoseconds: Int64? = nil,
        statusChangeTimeNanoseconds: Int64? = nil
    ) {
        self.byteCount = byteCount
        self.isDirectory = isDirectory
        self.identity = identity
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.statusChangeTimeNanoseconds = statusChangeTimeNanoseconds
    }
}

/// Stable local-file identity captured with `lstat` and carried from output
/// validation into the no-replace commit.
nonisolated struct FileIdentity: Sendable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
}

/// A one-shot identity; create a fresh value for every process start.
nonisolated struct ProcessExecutionID: RawRepresentable, Sendable, Equatable, Hashable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        rawValue = UUID()
    }
}

nonisolated enum ProcessStandardOutputDestination: Sendable, Equatable {
    case stream
    case existingFile(url: URL, expectedIdentity: FileIdentity)
}

nonisolated struct ProcessRequest: Sendable, Equatable {
    static let maximumDiagnosticByteLimit = 16 * 1_024 * 1_024
    static let maximumEventBufferCapacity = 4_096

    let id: ProcessExecutionID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let diagnosticByteLimit: Int
    let eventBufferCapacity: Int
    let cancellationPolicy: ProcessCancellationPolicy
    let standardOutputDestination: ProcessStandardOutputDestination

    init(
        id: ProcessExecutionID = ProcessExecutionID(),
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        diagnosticByteLimit: Int,
        eventBufferCapacity: Int = 256,
        cancellationPolicy: ProcessCancellationPolicy = .signalsOnly,
        standardOutputDestination: ProcessStandardOutputDestination = .stream
    ) throws {
        let validatedStandardOutputDestination:
            ProcessStandardOutputDestination
        switch standardOutputDestination {
        case .stream:
            validatedStandardOutputDestination = .stream
        case .existingFile(let url, let expectedIdentity):
            guard url.isFileURL,
                  url.path.hasPrefix("/"),
                  !url.path.contains("\0") else {
                throw ProcessContractValidationError.invalidRequest
            }
            validatedStandardOutputDestination = .existingFile(
                url: url.standardizedFileURL,
                expectedIdentity: expectedIdentity
            )
        }

        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0"),
              (1...Self.maximumDiagnosticByteLimit).contains(
                diagnosticByteLimit
              ),
              (1...Self.maximumEventBufferCapacity).contains(
                eventBufferCapacity
              ),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.contains("\0")
                      && !value.contains("\0")
              }) else {
            throw ProcessContractValidationError.invalidRequest
        }

        var controlledEnvironment = environment
        controlledEnvironment["LC_ALL"] = "C"
        controlledEnvironment["LANG"] = "C"

        self.id = id
        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        self.environment = controlledEnvironment
        self.diagnosticByteLimit = diagnosticByteLimit
        self.eventBufferCapacity = eventBufferCapacity
        self.cancellationPolicy = cancellationPolicy
        self.standardOutputDestination = validatedStandardOutputDestination
    }
}

nonisolated enum ProcessStandardInputPolicy: Sendable, Equatable {
    case closed
    case cancellationMessage(Data)
}

nonisolated struct ProcessCancellationPolicy: Sendable, Equatable {
    static let maximumMessageByteCount = 4_096
    static let maximumWait: Duration = .seconds(30)

    static var signalsOnly: ProcessCancellationPolicy {
        ProcessCancellationPolicy(
            uncheckedStandardInput: .closed,
            gracefulInputWait: .zero,
            interruptWait: .seconds(1),
            terminateWait: .seconds(1)
        )
    }

    let standardInput: ProcessStandardInputPolicy
    let gracefulInputWait: Duration
    let interruptWait: Duration
    let terminateWait: Duration

    init(
        standardInput: ProcessStandardInputPolicy,
        gracefulInputWait: Duration,
        interruptWait: Duration,
        terminateWait: Duration
    ) throws {
        if case .cancellationMessage(let message) = standardInput {
            guard !message.isEmpty,
                  message.count <= Self.maximumMessageByteCount else {
                throw ProcessContractValidationError.invalidCancellationPolicy
            }
        }

        guard gracefulInputWait >= .zero,
              gracefulInputWait <= Self.maximumWait,
              interruptWait >= .zero,
              interruptWait <= Self.maximumWait,
              terminateWait >= .zero,
              terminateWait <= Self.maximumWait else {
            throw ProcessContractValidationError.invalidCancellationPolicy
        }

        self.standardInput = standardInput
        self.gracefulInputWait = gracefulInputWait
        self.interruptWait = interruptWait
        self.terminateWait = terminateWait
    }

    private init(
        uncheckedStandardInput standardInput: ProcessStandardInputPolicy,
        gracefulInputWait: Duration,
        interruptWait: Duration,
        terminateWait: Duration
    ) {
        self.standardInput = standardInput
        self.gracefulInputWait = gracefulInputWait
        self.interruptWait = interruptWait
        self.terminateWait = terminateWait
    }
}

nonisolated enum ProcessEvent: Sendable, Equatable {
    case standardOutput(Data)
    case standardError(Data)
    case terminated(ProcessResult)
}

nonisolated struct BoundedData: Sendable, Equatable {
    let data: Data
    let byteLimit: Int
    let wasTruncated: Bool

    init(data: Data, byteLimit: Int, wasTruncated: Bool) throws {
        guard byteLimit > 0, data.count <= byteLimit else {
            throw ProcessContractValidationError.invalidBoundedData
        }
        self.data = data
        self.byteLimit = byteLimit
        self.wasTruncated = wasTruncated
    }
}

nonisolated struct ProcessResult: Sendable, Equatable {
    let executionID: ProcessExecutionID
    let processIdentifier: Int32
    let termination: ProcessTerminationStatus
    let diagnosticTail: BoundedData
    let wasCancellationRequested: Bool
    let lastCancellationStep: ProcessCancellationStep?
}

nonisolated struct ProcessTerminationStatus: Sendable, Equatable {
    let status: Int32
    let reason: ProcessExitReason
}

nonisolated enum ProcessExitReason: Sendable, Equatable {
    case exit
    case uncaughtSignal
}

nonisolated enum ProcessCancellationStep: Sendable, Equatable {
    case gracefulInput
    case interrupt
    case terminate
    case kill
}

nonisolated enum ProcessContractValidationError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidCancellationPolicy
    case invalidBoundedData
}
