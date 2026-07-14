import Darwin
import Foundation

nonisolated enum ProcessOutputChannel: Sendable, Equatable {
    case standardOutput
    case standardError
}

nonisolated enum ProcessRunnerError: Error, Sendable, Equatable {
    case executionIDAlreadyUsed(ProcessExecutionID)
    case standardInputConfigurationFailed(ProcessExecutionID)
    case standardOutputConfigurationFailed(ProcessExecutionID)
    case launchFailed(ProcessExecutionID)
    case outputReadFailed(ProcessExecutionID, ProcessOutputChannel)
    case eventBufferOverflow(ProcessExecutionID)
}

/// Launches direct child executables without a shell and owns every `Process`
/// instance for its full lifetime.
///
/// Cancellation guarantees teardown of the direct child only. Descendant
/// process groups are intentionally outside this generic runner's contract.
actor ProcessRunner: ProcessRunning {
    private static let outputChunkByteCount = 16 * 1_024

    private enum ExecutionBackend {
        case foundation
        case descriptor
    }

    private struct ExecutionToken: Sendable, Equatable {
        let rawValue = UUID()
    }

    private final class ExecutionState {
        let token: ExecutionToken
        let request: ProcessRequest
        let process: Process
        let standardOutputPipe: Pipe?
        let standardErrorPipe: Pipe
        let standardInputPipe: Pipe?
        let continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation

        var processIdentifier: Int32 = 0
        var standardInputWriter: FileHandle?
        var standardOutputTask: Task<Void, Never>?
        var standardErrorTask: Task<Void, Never>?
        var cancellationTask: Task<Void, Never>?
        var termination: ProcessTerminationStatus?
        var standardOutputFinished = false
        var standardErrorFinished = false
        var diagnosticTail: DiagnosticTail
        var terminalError: ProcessRunnerError?
        var wasCancellationRequested = false
        var lastCancellationStep: ProcessCancellationStep?
        var completionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var finalized = false

        init(
            token: ExecutionToken,
            request: ProcessRequest,
            process: Process,
            standardOutputPipe: Pipe?,
            standardErrorPipe: Pipe,
            standardInputPipe: Pipe?,
            continuation: AsyncThrowingStream<ProcessEvent, any Error>.Continuation
        ) {
            self.token = token
            self.request = request
            self.process = process
            self.standardOutputPipe = standardOutputPipe
            self.standardErrorPipe = standardErrorPipe
            self.standardInputPipe = standardInputPipe
            self.continuation = continuation
            diagnosticTail = DiagnosticTail(limit: request.diagnosticByteLimit)
        }
    }

    private struct DiagnosticTail {
        let limit: Int
        private var storage: [UInt8]
        private var retainedCount = 0
        private var nextReplacementIndex = 0
        private(set) var wasTruncated = false

        init(limit: Int) {
            self.limit = limit
            storage = [UInt8](repeating: 0, count: limit)
        }

        var data: Data {
            guard retainedCount == limit else {
                return Data(storage.prefix(retainedCount))
            }
            guard nextReplacementIndex != 0 else {
                return Data(storage)
            }

            var ordered = Data(capacity: limit)
            ordered.append(contentsOf: storage[nextReplacementIndex...])
            ordered.append(contentsOf: storage[..<nextReplacementIndex])
            return ordered
        }

        mutating func append(_ newData: Data) {
            for byte in newData {
                if retainedCount < limit {
                    storage[retainedCount] = byte
                    retainedCount += 1
                } else {
                    storage[nextReplacementIndex] = byte
                    nextReplacementIndex = (nextReplacementIndex + 1) % limit
                    wasTruncated = true
                }
            }
        }
    }

    private var executions: [ProcessExecutionID: ExecutionState] = [:]
    /// Execution IDs are intentionally one-shot across both backends. Keeping
    /// the route at the facade prevents an actor-reentrancy window where the
    /// same ID could otherwise be active in Foundation.Process and posix_spawn
    /// simultaneously.
    private var usedExecutionIDs: Set<ProcessExecutionID> = []
    private var activeExecutionBackends: [
        ProcessExecutionID: ExecutionBackend
    ] = [:]
    private let descriptorRunner = DescriptorProcessRunner()

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        guard usedExecutionIDs.insert(request.id).inserted else {
            throw ProcessRunnerError.executionIDAlreadyUsed(request.id)
        }
        if request.inheritedFileDescriptor != nil {
            activeExecutionBackends[request.id] = .descriptor
            do {
                return try await descriptorRunner.start(
                    request,
                    onCompletion: { [weak self] executionID in
                        await self?.descriptorExecutionDidFinish(
                            executionID
                        )
                    }
                )
            } catch {
                activeExecutionBackends.removeValue(forKey: request.id)
                throw error
            }
        }

        let streamPair = AsyncThrowingStream<ProcessEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(request.eventBufferCapacity)
        )
        let stream = streamPair.stream
        let continuation = streamPair.continuation
        let process = Process()
        let standardErrorPipe = Pipe()
        let standardInputPipe: Pipe?

        switch request.cancellationPolicy.standardInput {
        case .closed:
            standardInputPipe = nil
            process.standardInput = FileHandle.nullDevice
        case .cancellationMessage:
            let pipe = Pipe()
            guard fcntl(
                pipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            ) != -1 else {
                Self.closeAllHandles(
                    standardErrorPipe,
                    pipe
                )
                continuation.finish(
                    throwing: ProcessRunnerError.standardInputConfigurationFailed(
                        request.id
                    )
                )
                throw ProcessRunnerError.standardInputConfigurationFailed(
                    request.id
                )
            }
            standardInputPipe = pipe
            process.standardInput = pipe
        }

        let standardOutputPipe: Pipe?
        let standardOutputFile: FileHandle?
        switch request.standardOutputDestination {
        case .stream:
            let pipe = Pipe()
            standardOutputPipe = pipe
            standardOutputFile = nil
            process.standardOutput = pipe
        case .existingFile(let url, let expectedIdentity):
            do {
                let file = try Self.openExistingStandardOutput(
                    at: url,
                    expectedIdentity: expectedIdentity,
                    executionID: request.id
                )
                standardOutputPipe = nil
                standardOutputFile = file
                process.standardOutput = file
            } catch let runnerError as ProcessRunnerError {
                Self.closeAllHandles(standardErrorPipe, standardInputPipe)
                continuation.finish(throwing: runnerError)
                throw runnerError
            } catch {
                Self.closeAllHandles(standardErrorPipe, standardInputPipe)
                let runnerError = ProcessRunnerError
                    .standardOutputConfigurationFailed(request.id)
                continuation.finish(throwing: runnerError)
                throw runnerError
            }
        }

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardError = standardErrorPipe

        let token = ExecutionToken()
        let state = ExecutionState(
            token: token,
            request: request,
            process: process,
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe,
            standardInputPipe: standardInputPipe,
            continuation: continuation
        )
        state.standardInputWriter = standardInputPipe?.fileHandleForWriting
        activeExecutionBackends[request.id] = .foundation
        executions[request.id] = state

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else {
                return
            }
            Task {
                await self?.streamWasCancelled(
                    executionID: request.id,
                    token: token
                )
            }
        }

        // This strong capture keeps the actor and its execution state alive
        // even if a child closes both pipes before terminating. Finalization
        // clears the handler and breaks the temporary ownership cycle.
        process.terminationHandler = { [self] _ in
            Task {
                await self.recordTermination(
                    executionID: request.id,
                    token: token
                )
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.onTermination = nil
            executions.removeValue(forKey: request.id)
            activeExecutionBackends.removeValue(forKey: request.id)
            Self.closeAllHandles(
                standardOutputPipe,
                standardErrorPipe,
                standardInputPipe
            )
            try? standardOutputFile?.close()
            let runnerError = ProcessRunnerError.launchFailed(request.id)
            continuation.finish(throwing: runnerError)
            throw runnerError
        }

        state.processIdentifier = process.processIdentifier

        // The child inherited these descriptors during `run()`. Closing only
        // the parent's copies makes EOF observable after the child exits.
        try? standardOutputPipe?.fileHandleForWriting.close()
        try? standardOutputFile?.close()
        try? standardErrorPipe.fileHandleForWriting.close()
        try? standardInputPipe?.fileHandleForReading.close()

        if let standardOutputPipe {
            state.standardOutputTask = Task.detached(priority: .utility) {
                await Self.drain(
                    standardOutputPipe.fileHandleForReading,
                    channel: .standardOutput,
                    executionID: request.id,
                    token: token,
                    runner: self
                )
            }
        } else {
            // A regular output file has no parent-side read endpoint. The
            // child owns its inherited descriptor after launch, so stdout is
            // already complete from the runner's event-stream perspective.
            state.standardOutputFinished = true
        }
        state.standardErrorTask = Task.detached(priority: .utility) {
            await Self.drain(
                standardErrorPipe.fileHandleForReading,
                channel: .standardError,
                executionID: request.id,
                token: token,
                runner: self
            )
        }

        return stream
    }

    func cancel(executionID: ProcessExecutionID) async {
        switch activeExecutionBackends[executionID] {
        case .descriptor:
            await descriptorRunner.cancel(executionID: executionID)
            return
        case .foundation:
            break
        case nil:
            return
        }

        guard let state = executions[executionID] else {
            return
        }

        beginCancellation(for: state)
        let token = state.token
        let waiterID = UUID()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      let activeState = currentState(
                          executionID: executionID,
                          token: token
                      ) else {
                    continuation.resume()
                    return
                }
                activeState.completionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.stopWaitingForCompletion(
                    executionID: executionID,
                    token: token,
                    waiterID: waiterID
                )
            }
        }
    }

    func activeExecutionCount() -> Int {
        activeExecutionBackends.count
    }

    private func descriptorExecutionDidFinish(
        _ executionID: ProcessExecutionID
    ) {
        guard activeExecutionBackends[executionID] == .descriptor else {
            return
        }
        activeExecutionBackends.removeValue(forKey: executionID)
    }

    private func streamWasCancelled(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ) else {
            return
        }
        beginCancellation(for: state)
    }

    private func stopWaitingForCompletion(
        executionID: ProcessExecutionID,
        token: ExecutionToken,
        waiterID: UUID
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), let waiter = state.completionWaiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        waiter.resume()
    }

    private func received(
        _ data: Data,
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), !state.finalized else {
            return
        }

        if channel == .standardError {
            state.diagnosticTail.append(data)
        }

        guard state.terminalError == nil else {
            return
        }

        let event: ProcessEvent = switch channel {
        case .standardOutput:
            .standardOutput(data)
        case .standardError:
            .standardError(data)
        }

        switch state.continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            state.terminalError = .eventBufferOverflow(executionID)
            beginCancellation(for: state)
        case .terminated:
            beginCancellation(for: state)
        @unknown default:
            state.terminalError = .eventBufferOverflow(executionID)
            beginCancellation(for: state)
        }
    }

    private func outputFinished(
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), !state.finalized else {
            return
        }

        switch channel {
        case .standardOutput:
            state.standardOutputFinished = true
        case .standardError:
            state.standardErrorFinished = true
        }
        finalizeIfReady(executionID: executionID, token: token)
    }

    private func outputReadFailed(
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), !state.finalized else {
            return
        }

        if state.terminalError == nil {
            state.terminalError = .outputReadFailed(executionID, channel)
        }
        switch channel {
        case .standardOutput:
            state.standardOutputFinished = true
        case .standardError:
            state.standardErrorFinished = true
        }
        beginCancellation(for: state)
        finalizeIfReady(executionID: executionID, token: token)
    }

    private func recordTermination(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ),
              state.termination == nil,
              !state.finalized else {
            return
        }

        let reason: ProcessExitReason = switch state.process.terminationReason {
        case .exit:
            .exit
        case .uncaughtSignal:
            .uncaughtSignal
        @unknown default:
            .uncaughtSignal
        }
        state.termination = ProcessTerminationStatus(
            status: state.process.terminationStatus,
            reason: reason
        )
        state.cancellationTask?.cancel()
        try? state.standardInputWriter?.close()
        state.standardInputWriter = nil
        finalizeIfReady(executionID: executionID, token: token)
    }

    private func beginCancellation(for state: ExecutionState) {
        guard !state.wasCancellationRequested,
              !state.finalized,
              state.termination == nil else {
            return
        }

        state.wasCancellationRequested = true
        let executionID = state.request.id
        let token = state.token
        state.cancellationTask = Task { [weak self] in
            await self?.performCancellation(
                executionID: executionID,
                token: token
            )
        }
    }

    private func performCancellation(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) async {
        guard let initialState = currentState(
            executionID: executionID,
            token: token
        ) else {
            return
        }

        switch initialState.request.cancellationPolicy.standardInput {
        case .closed:
            break
        case .cancellationMessage(let message):
            initialState.lastCancellationStep = .gracefulInput
            if let writer = initialState.standardInputWriter {
                try? writer.write(contentsOf: message)
                try? writer.close()
                initialState.standardInputWriter = nil
            }
            guard await waitUnlessCancelled(
                for: initialState.request.cancellationPolicy.gracefulInputWait
            ) else {
                return
            }
        }

        guard let interruptState = runningState(
            executionID: executionID,
            token: token
        ) else {
            return
        }
        interruptState.lastCancellationStep = .interrupt
        interruptState.process.interrupt()
        guard await waitUnlessCancelled(
            for: interruptState.request.cancellationPolicy.interruptWait
        ) else {
            return
        }

        guard let terminateState = runningState(
            executionID: executionID,
            token: token
        ) else {
            return
        }
        terminateState.lastCancellationStep = .terminate
        terminateState.process.terminate()
        guard await waitUnlessCancelled(
            for: terminateState.request.cancellationPolicy.terminateWait
        ) else {
            return
        }

        guard let killState = runningState(
            executionID: executionID,
            token: token
        ) else {
            return
        }
        killState.lastCancellationStep = .kill
        _ = Darwin.kill(killState.process.processIdentifier, SIGKILL)
    }

    private func runningState(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) -> ExecutionState? {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ),
              !state.finalized,
              state.termination == nil,
              state.process.isRunning else {
            return nil
        }
        return state
    }

    private func currentState(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) -> ExecutionState? {
        guard let state = executions[executionID], state.token == token else {
            return nil
        }
        return state
    }

    private func waitUnlessCancelled(for duration: Duration) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard duration > .zero else {
            return true
        }
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func finalizeIfReady(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ),
              !state.finalized,
              let termination = state.termination,
              state.standardOutputFinished,
              state.standardErrorFinished else {
            return
        }

        state.finalized = true
        state.cancellationTask?.cancel()
        state.process.terminationHandler = nil
        try? state.standardInputWriter?.close()
        state.standardInputWriter = nil
        state.continuation.onTermination = nil

        if let terminalError = state.terminalError {
            state.continuation.finish(throwing: terminalError)
        } else {
            let diagnosticTail = try? BoundedData(
                data: state.diagnosticTail.data,
                byteLimit: state.diagnosticTail.limit,
                wasTruncated: state.diagnosticTail.wasTruncated
            )

            if let diagnosticTail {
                let result = ProcessResult(
                    executionID: executionID,
                    processIdentifier: state.processIdentifier,
                    termination: termination,
                    diagnosticTail: diagnosticTail,
                    wasCancellationRequested: state.wasCancellationRequested,
                    lastCancellationStep: state.lastCancellationStep
                )

                switch state.continuation.yield(.terminated(result)) {
                case .enqueued:
                    state.continuation.finish()
                case .dropped:
                    state.continuation.finish(
                        throwing: ProcessRunnerError.eventBufferOverflow(
                            executionID
                        )
                    )
                case .terminated:
                    state.continuation.finish()
                @unknown default:
                    state.continuation.finish(
                        throwing: ProcessRunnerError.eventBufferOverflow(
                            executionID
                        )
                    )
                }
            } else {
                state.continuation.finish(
                    throwing: ProcessRunnerError.outputReadFailed(
                        executionID,
                        .standardError
                    )
                )
            }
        }

        executions.removeValue(forKey: executionID)
        activeExecutionBackends.removeValue(forKey: executionID)
        let waiters = Array(state.completionWaiters.values)
        state.completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private nonisolated static func drain(
        _ handle: FileHandle,
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken,
        runner: ProcessRunner
    ) async {
        var buffer = [UInt8](repeating: 0, count: outputChunkByteCount)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    handle.fileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }

            if byteCount > 0 {
                let data = Data(buffer.prefix(byteCount))
                await runner.received(
                    data,
                    channel: channel,
                    executionID: executionID,
                    token: token
                )
                continue
            }

            if byteCount < 0 && errno == EINTR {
                continue
            }

            if byteCount < 0 {
                try? handle.close()
                await runner.outputReadFailed(
                    channel: channel,
                    executionID: executionID,
                    token: token
                )
                return
            }

            try? handle.close()
            await runner.outputFinished(
                channel: channel,
                executionID: executionID,
                token: token
            )
            return
        }
    }

    private nonisolated static func openExistingStandardOutput(
        at url: URL,
        expectedIdentity: FileIdentity,
        executionID: ProcessExecutionID
    ) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.open(
                path,
                O_WRONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ProcessRunnerError.standardOutputConfigurationFailed(
                executionID
            )
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              mode_t(status.st_mode) & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size == 0,
              FileIdentity(
                  device: UInt64(status.st_dev),
                  inode: UInt64(status.st_ino)
              ) == expectedIdentity else {
            Darwin.close(descriptor)
            throw ProcessRunnerError.standardOutputConfigurationFailed(
                executionID
            )
        }

        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func closeAllHandles(_ pipes: Pipe?...) {
        for pipe in pipes.compactMap({ $0 }) {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}
