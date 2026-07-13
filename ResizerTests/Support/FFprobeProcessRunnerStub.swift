import Foundation
@testable import Resizer

nonisolated enum FFprobeRunnerInstruction: Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case terminated(FFprobeRunnerTermination)
}

nonisolated struct FFprobeRunnerTermination: Sendable {
    let executionID: ProcessExecutionID?
    let status: Int32
    let reason: ProcessExitReason
    let diagnosticTail: BoundedData

    init(
        executionID: ProcessExecutionID? = nil,
        status: Int32 = 0,
        reason: ProcessExitReason = .exit,
        diagnosticData: Data = Data(),
        diagnosticByteLimit: Int = 1_024,
        diagnosticWasTruncated: Bool = false
    ) throws {
        self.executionID = executionID
        self.status = status
        self.reason = reason
        diagnosticTail = try BoundedData(
            data: diagnosticData,
            byteLimit: diagnosticByteLimit,
            wasTruncated: diagnosticWasTruncated
        )
    }
}

nonisolated struct FFprobeRunnerScript: Sendable {
    nonisolated enum Ending: Sendable {
        case finish
        case holdOpen
    }

    let instructions: [FFprobeRunnerInstruction]
    let ending: Ending

    init(
        instructions: [FFprobeRunnerInstruction],
        ending: Ending = .finish
    ) {
        self.instructions = instructions
        self.ending = ending
    }

    static func success(
        standardOutputChunks: [Data]
    ) throws -> FFprobeRunnerScript {
        FFprobeRunnerScript(
            instructions: standardOutputChunks.map(
                FFprobeRunnerInstruction.standardOutput
            ) + [
                .terminated(try FFprobeRunnerTermination()),
            ]
        )
    }
}

nonisolated enum FFprobeProcessRunnerStubError: Error, Sendable, Equatable {
    case missingScript
}

actor FFprobeProcessRunnerStub: ProcessRunning {
    private var scripts: [FFprobeRunnerScript]
    private let blocksCancellation: Bool
    private var cancellationWasReleased: Bool
    private var requests: [ProcessRequest] = []
    private var cancellationRequests: [ProcessExecutionID] = []
    private var heldContinuations: [
        ProcessExecutionID:
            AsyncThrowingStream<ProcessEvent, any Error>.Continuation
    ] = [:]
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        scripts: [FFprobeRunnerScript],
        blocksCancellation: Bool = false
    ) {
        self.scripts = scripts
        self.blocksCancellation = blocksCancellation
        cancellationWasReleased = !blocksCancellation
    }

    init(
        script: FFprobeRunnerScript,
        blocksCancellation: Bool = false
    ) {
        scripts = [script]
        self.blocksCancellation = blocksCancellation
        cancellationWasReleased = !blocksCancellation
    }

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        guard !scripts.isEmpty else {
            throw FFprobeProcessRunnerStubError.missingScript
        }

        requests.append(request)
        let script = scripts.removeFirst()
        let pair = AsyncThrowingStream<ProcessEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )

        for instruction in script.instructions {
            switch instruction {
            case .standardOutput(let data):
                _ = pair.continuation.yield(.standardOutput(data))
            case .standardError(let data):
                _ = pair.continuation.yield(.standardError(data))
            case .terminated(let termination):
                _ = pair.continuation.yield(
                    .terminated(
                        ProcessResult(
                            executionID: termination.executionID ?? request.id,
                            processIdentifier: 42,
                            termination: ProcessTerminationStatus(
                                status: termination.status,
                                reason: termination.reason
                            ),
                            diagnosticTail: termination.diagnosticTail,
                            wasCancellationRequested: false,
                            lastCancellationStep: nil
                        )
                    )
                )
            }
        }

        switch script.ending {
        case .finish:
            pair.continuation.finish()
        case .holdOpen:
            heldContinuations[request.id] = pair.continuation
        }
        return pair.stream
    }

    func cancel(executionID: ProcessExecutionID) async {
        cancellationRequests.append(executionID)
        if blocksCancellation, !cancellationWasReleased {
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
        }
        heldContinuations.removeValue(forKey: executionID)?.finish()
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }

    func recordedCancellationRequests() -> [ProcessExecutionID] {
        cancellationRequests
    }

    func releaseCancellation() {
        cancellationWasReleased = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor FFprobeOperationCompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
