import Foundation

nonisolated protocol MediaProbing: Sendable {
    func probe(_ sourceURL: URL) async throws -> MediaInfo
}

nonisolated protocol Transcoding: Sendable {
    func transcode(
        _ request: TranscodeRequest,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult

    func cancel(jobID: CompressionJob.ID) async
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
    func commitWithoutReplacing(_ plan: OutputPlan) async throws
    func cleanupTemporaryOutput(_ plan: OutputPlan) async throws
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

    init(byteCount: Int64) throws {
        guard byteCount > 0 else {
            throw TranscodeContractValidationError.invalidResult
        }
        self.byteCount = byteCount
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

nonisolated enum OutputPlanValidationError: Error, Sendable, Equatable {
    case invalidPlan
}

nonisolated struct FileMetadata: Sendable, Equatable {
    let byteCount: Int64
    let isDirectory: Bool
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

    init(
        id: ProcessExecutionID = ProcessExecutionID(),
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        diagnosticByteLimit: Int,
        eventBufferCapacity: Int = 256,
        cancellationPolicy: ProcessCancellationPolicy = .signalsOnly
    ) throws {
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
