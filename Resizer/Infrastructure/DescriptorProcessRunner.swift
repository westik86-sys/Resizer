import Darwin
import Foundation

/// Runs direct child executables that need one pre-opened file descriptor.
///
/// The inherited descriptor is independent of standard output, which remains
/// available for machine-readable progress. Cancellation targets the direct
/// child only; descendant process groups are outside this runner's contract.
actor DescriptorProcessRunner: ProcessRunning {
    private static let outputChunkByteCount = 16 * 1_024

    private struct ExecutionToken: Sendable, Equatable {
        let rawValue = UUID()
    }

    private final class ExecutionState {
        let token: ExecutionToken
        let request: ProcessRequest
        let processIdentifier: pid_t
        let continuation:
            AsyncThrowingStream<ProcessEvent, any Error>.Continuation
        let onCompletion: @Sendable (ProcessExecutionID) async -> Void

        var standardInputWriter: Int32?
        var standardOutputTask: Task<Void, Never>?
        var standardErrorTask: Task<Void, Never>?
        var waitTask: Task<Void, Never>?
        var cancellationTask: Task<Void, Never>?
        var termination: ProcessTerminationStatus?
        var standardOutputFinished = false
        var standardErrorFinished = false
        var diagnosticTail: DiagnosticTail
        var terminalError: ProcessRunnerError?
        var wasCancellationRequested = false
        var lastCancellationStep: ProcessCancellationStep?
        var completionWaiters: [
            UUID: CheckedContinuation<Void, Never>
        ] = [:]
        var finalized = false

        init(
            token: ExecutionToken,
            request: ProcessRequest,
            processIdentifier: pid_t,
            standardInputWriter: Int32?,
            continuation:
                AsyncThrowingStream<ProcessEvent, any Error>.Continuation,
            onCompletion:
                @escaping @Sendable (ProcessExecutionID) async -> Void
        ) {
            self.token = token
            self.request = request
            self.processIdentifier = processIdentifier
            self.standardInputWriter = standardInputWriter
            self.continuation = continuation
            self.onCompletion = onCompletion
            diagnosticTail = DiagnosticTail(
                limit: request.diagnosticByteLimit
            )
        }

        deinit {
            if let standardInputWriter {
                Darwin.close(standardInputWriter)
            }
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
                    nextReplacementIndex =
                        (nextReplacementIndex + 1) % limit
                    wasTruncated = true
                }
            }
        }
    }

    private var executions: [ProcessExecutionID: ExecutionState] = [:]

    func start(
        _ request: ProcessRequest
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        try await start(request, onCompletion: { _ in })
    }

    func start(
        _ request: ProcessRequest,
        onCompletion:
            @escaping @Sendable (ProcessExecutionID) async -> Void
    ) async throws -> AsyncThrowingStream<ProcessEvent, any Error> {
        guard executions[request.id] == nil else {
            throw ProcessRunnerError.executionIDAlreadyUsed(request.id)
        }

        let streamPair = AsyncThrowingStream<
            ProcessEvent,
            any Error
        >.makeStream(
            bufferingPolicy: .bufferingOldest(
                request.eventBufferCapacity
            )
        )
        let stream = streamPair.stream
        let continuation = streamPair.continuation

        guard case .stream = request.standardOutputDestination,
              let inheritedDescriptor = request.inheritedFileDescriptor,
              let leaseDescriptor = inheritedDescriptor.lease.fileDescriptor,
              Self.isOpenRegularFile(leaseDescriptor) else {
            let error = ProcessRunnerError.standardOutputConfigurationFailed(
                request.id
            )
            continuation.finish(throwing: error)
            throw error
        }

        let spawned: DescriptorSpawnedProcess
        do {
            spawned = try Self.spawn(
                request: request,
                inheritedDescriptor: inheritedDescriptor,
                leaseDescriptor: leaseDescriptor
            )
        } catch let failure as DescriptorSpawnFailure {
            let error = failure.runnerError(executionID: request.id)
            continuation.finish(throwing: error)
            throw error
        } catch {
            let runnerError = ProcessRunnerError.launchFailed(request.id)
            continuation.finish(throwing: runnerError)
            throw runnerError
        }

        let standardInputWriter: Int32?
        switch request.cancellationPolicy.standardInput {
        case .closed:
            Self.closeDescriptor(spawned.standardInputWriter)
            standardInputWriter = nil
        case .cancellationMessage:
            standardInputWriter = spawned.standardInputWriter
        }

        let token = ExecutionToken()
        let state = ExecutionState(
            token: token,
            request: request,
            processIdentifier: spawned.processIdentifier,
            standardInputWriter: standardInputWriter,
            continuation: continuation,
            onCompletion: onCompletion
        )
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

        state.standardOutputTask = Task.detached(priority: .utility) {
            await Self.drain(
                spawned.standardOutputReader,
                channel: .standardOutput,
                executionID: request.id,
                token: token,
                runner: self
            )
        }
        state.standardErrorTask = Task.detached(priority: .utility) {
            await Self.drain(
                spawned.standardErrorReader,
                channel: .standardError,
                executionID: request.id,
                token: token,
                runner: self
            )
        }
        state.waitTask = Task.detached(priority: .utility) {
            let waitSucceeded = Self.waitUntilExitedWithoutReaping(
                spawned.processIdentifier
            )
            await self.reapAfterWaitNotification(
                executionID: request.id,
                token: token,
                waitSucceeded: waitSucceeded
            )
        }

        return stream
    }

    func cancel(executionID: ProcessExecutionID) async {
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
        executions.count
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
    ) async {
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
        await finalizeIfReady(executionID: executionID, token: token)
    }

    private func outputReadFailed(
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) async {
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
        await finalizeIfReady(executionID: executionID, token: token)
    }

    private func reapAfterWaitNotification(
        executionID: ProcessExecutionID,
        token: ExecutionToken,
        waitSucceeded: Bool
    ) async {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), state.termination == nil, !state.finalized else {
            return
        }

        if !waitSucceeded, state.terminalError == nil {
            state.terminalError = .launchFailed(executionID)
        }

        var waitStatus: Int32 = 0
        let reaped = Self.reap(
            state.processIdentifier,
            waitStatus: &waitStatus
        )
        if reaped {
            state.termination = Self.terminationStatus(
                from: waitStatus
            )
        } else {
            if state.terminalError == nil {
                state.terminalError = .launchFailed(executionID)
            }
            state.termination = ProcessTerminationStatus(
                status: -1,
                reason: .uncaughtSignal
            )
        }

        state.cancellationTask?.cancel()
        closeStandardInput(for: state)
        await finalizeIfReady(executionID: executionID, token: token)
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
                _ = Self.writeAll(message, to: writer)
                closeStandardInput(for: initialState)
            }
            guard await waitUnlessCancelled(
                for: initialState.request.cancellationPolicy
                    .gracefulInputWait
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
        _ = Darwin.kill(interruptState.processIdentifier, SIGINT)
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
        _ = Darwin.kill(terminateState.processIdentifier, SIGTERM)
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
        _ = Darwin.kill(killState.processIdentifier, SIGKILL)
    }

    private func runningState(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) -> ExecutionState? {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), !state.finalized, state.termination == nil else {
            return nil
        }
        return state
    }

    private func currentState(
        executionID: ProcessExecutionID,
        token: ExecutionToken
    ) -> ExecutionState? {
        guard let state = executions[executionID],
              state.token == token else {
            return nil
        }
        return state
    }

    private func closeStandardInput(for state: ExecutionState) {
        guard let writer = state.standardInputWriter else {
            return
        }
        state.standardInputWriter = nil
        Self.closeDescriptor(writer)
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
    ) async {
        guard let state = currentState(
            executionID: executionID,
            token: token
        ), !state.finalized,
              let termination = state.termination,
              state.standardOutputFinished,
              state.standardErrorFinished else {
            return
        }

        state.finalized = true
        state.cancellationTask?.cancel()
        closeStandardInput(for: state)
        state.continuation.onTermination = nil

        // Retire the execution from both runner registries before publishing
        // the terminal stream event. A consumer that observes stream EOF can
        // therefore rely on `activeExecutionCount()` already being zero.
        executions.removeValue(forKey: executionID)
        await state.onCompletion(executionID)

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
                    wasCancellationRequested:
                        state.wasCancellationRequested,
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

        let waiters = Array(state.completionWaiters.values)
        state.completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private nonisolated static func spawn(
        request: ProcessRequest,
        inheritedDescriptor: ProcessInheritedFileDescriptor,
        leaseDescriptor: Int32
    ) throws -> DescriptorSpawnedProcess {
        var standardInput = try DescriptorPipePair.make(
            avoiding: inheritedDescriptor.childDescriptor,
            suppressBrokenPipeSignal: true
        )
        defer { standardInput.closeBoth() }
        var standardOutput = try DescriptorPipePair.make(
            avoiding: inheritedDescriptor.childDescriptor
        )
        defer { standardOutput.closeBoth() }
        var standardError = try DescriptorPipePair.make(
            avoiding: inheritedDescriptor.childDescriptor
        )
        defer { standardError.closeBoth() }
        let heldOutput = try Self.duplicateDescriptor(
            leaseDescriptor,
            avoiding: inheritedDescriptor.childDescriptor
        )
        defer { Self.closeDescriptor(heldOutput) }

        var actions: posix_spawn_file_actions_t?
        try Self.checkSpawnCall(
            posix_spawn_file_actions_init(&actions),
            category: .launch
        )
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }

        try Self.checkSpawnCall(
            posix_spawn_file_actions_adddup2(
                &actions,
                standardInput.readDescriptor,
                STDIN_FILENO
            ),
            category: .standardInput
        )
        try Self.checkSpawnCall(
            posix_spawn_file_actions_adddup2(
                &actions,
                standardOutput.writeDescriptor,
                STDOUT_FILENO
            ),
            category: .standardOutput
        )
        try Self.checkSpawnCall(
            posix_spawn_file_actions_adddup2(
                &actions,
                standardError.writeDescriptor,
                STDERR_FILENO
            ),
            category: .standardOutput
        )
        try Self.checkSpawnCall(
            posix_spawn_file_actions_adddup2(
                &actions,
                heldOutput,
                inheritedDescriptor.childDescriptor
            ),
            category: .standardOutput
        )

        for descriptor in [
            standardInput.readDescriptor,
            standardOutput.writeDescriptor,
            standardError.writeDescriptor,
            heldOutput
        ] {
            try Self.checkSpawnCall(
                posix_spawn_file_actions_addclose(&actions, descriptor),
                category: .launch
            )
        }

        var attributes: posix_spawnattr_t?
        try Self.checkSpawnCall(
            posix_spawnattr_init(&attributes),
            category: .launch
        )
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        try Self.checkSpawnCall(
            posix_spawnattr_setsigmask(
                &attributes,
                &emptySignalMask
            ),
            category: .launch
        )

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGHUP)
        sigaddset(&defaultSignals, SIGPIPE)
        try Self.checkSpawnCall(
            posix_spawnattr_setsigdefault(
                &attributes,
                &defaultSignals
            ),
            category: .launch
        )

        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try Self.checkSpawnCall(
            posix_spawnattr_setflags(&attributes, flags),
            category: .launch
        )

        let executablePath = request.executableURL.path
        let arguments = try DescriptorCStringVector(
            [executablePath] + request.arguments
        )
        let environment = try DescriptorCStringVector(
            request.environment
                .sorted { lhs, rhs in lhs.key < rhs.key }
                .map { key, value in "\(key)=\(value)" }
        )
        var processIdentifier: pid_t = 0
        let spawnResult = executablePath.withCString { executable in
            arguments.withMutableBuffer { argumentVector in
                environment.withMutableBuffer { environmentVector in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &actions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }
        try Self.checkSpawnCall(spawnResult, category: .launch)

        let parentInput = standardInput.takeWriteDescriptor()
        let parentOutput = standardOutput.takeReadDescriptor()
        let parentError = standardError.takeReadDescriptor()

        return DescriptorSpawnedProcess(
            processIdentifier: processIdentifier,
            standardInputWriter: parentInput,
            standardOutputReader: parentOutput,
            standardErrorReader: parentError
        )
    }

    private nonisolated static func drain(
        _ descriptor: Int32,
        channel: ProcessOutputChannel,
        executionID: ProcessExecutionID,
        token: ExecutionToken,
        runner: DescriptorProcessRunner
    ) async {
        defer {
            Self.closeDescriptor(descriptor)
        }

        var buffer = [UInt8](
            repeating: 0,
            count: outputChunkByteCount
        )
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
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

            if byteCount < 0, errno == EINTR {
                continue
            }

            if byteCount < 0 {
                await runner.outputReadFailed(
                    channel: channel,
                    executionID: executionID,
                    token: token
                )
                return
            }

            await runner.outputFinished(
                channel: channel,
                executionID: executionID,
                token: token
            )
            return
        }
    }

    private nonisolated static func waitUntilExitedWithoutReaping(
        _ processIdentifier: pid_t
    ) -> Bool {
        var information = siginfo_t()
        while true {
            if waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOWAIT
            ) == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }

            if errno != ECHILD {
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
            return false
        }
    }

    private nonisolated static func reap(
        _ processIdentifier: pid_t,
        waitStatus: inout Int32
    ) -> Bool {
        while true {
            let result = waitpid(processIdentifier, &waitStatus, 0)
            if result == processIdentifier {
                return true
            }
            if result == -1, errno == EINTR {
                continue
            }
            return false
        }
    }

    private nonisolated static func terminationStatus(
        from waitStatus: Int32
    ) -> ProcessTerminationStatus {
        // Darwin exposes these operations as C macros. WEXITED means stopped
        // states cannot reach this decoder, so the stable wait-status bit
        // layout is sufficient here.
        let lowBits = waitStatus & 0x7f
        if lowBits == 0 {
            return ProcessTerminationStatus(
                status: (waitStatus >> 8) & 0xff,
                reason: .exit
            )
        }
        return ProcessTerminationStatus(
            status: lowBits,
            reason: .uncaughtSignal
        )
    }

    private nonisolated static func isOpenRegularFile(
        _ descriptor: Int32
    ) -> Bool {
        guard fcntl(descriptor, F_GETFD) != -1 else {
            return false
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags != -1,
              statusFlags & O_ACCMODE == O_RDWR else {
            return false
        }
        var status = stat()
        return fstat(descriptor, &status) == 0
            && mode_t(status.st_mode) & mode_t(S_IFMT)
                == mode_t(S_IFREG)
    }

    private nonisolated static func duplicateDescriptor(
        _ descriptor: Int32,
        avoiding forbiddenDescriptor: Int32
    ) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        guard duplicate >= 0 else {
            throw DescriptorSpawnFailure.standardOutput
        }
        guard duplicate == forbiddenDescriptor else {
            return duplicate
        }

        let replacement = fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            forbiddenDescriptor + 1
        )
        closeDescriptor(duplicate)
        guard replacement >= 0 else {
            throw DescriptorSpawnFailure.standardOutput
        }
        return replacement
    }

    private nonisolated static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else {
                return true
            }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(
                    descriptor,
                    pointer,
                    remaining
                )
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private nonisolated static func checkSpawnCall(
        _ result: Int32,
        category: DescriptorSpawnFailure
    ) throws {
        guard result == 0 else {
            throw category
        }
    }

    private nonisolated static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.close(descriptor)
    }
}

nonisolated private struct DescriptorSpawnedProcess: Sendable {
    let processIdentifier: pid_t
    let standardInputWriter: Int32
    let standardOutputReader: Int32
    let standardErrorReader: Int32
}

nonisolated private enum DescriptorSpawnFailure: Error, Sendable {
    case standardInput
    case standardOutput
    case launch

    func runnerError(
        executionID: ProcessExecutionID
    ) -> ProcessRunnerError {
        switch self {
        case .standardInput:
            .standardInputConfigurationFailed(executionID)
        case .standardOutput:
            .standardOutputConfigurationFailed(executionID)
        case .launch:
            .launchFailed(executionID)
        }
    }
}

nonisolated private struct DescriptorPipePair {
    var readDescriptor: Int32
    var writeDescriptor: Int32

    static func make(
        avoiding forbiddenDescriptor: Int32,
        suppressBrokenPipeSignal: Bool = false
    ) throws -> DescriptorPipePair {
        var rawDescriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&rawDescriptors) == 0 else {
            throw DescriptorSpawnFailure.launch
        }

        var duplicatedRead: Int32 = -1
        var duplicatedWrite: Int32 = -1
        do {
            duplicatedRead = try duplicate(
                rawDescriptors[0],
                avoiding: forbiddenDescriptor
            )
            duplicatedWrite = try duplicate(
                rawDescriptors[1],
                avoiding: forbiddenDescriptor
            )
            if suppressBrokenPipeSignal,
               fcntl(duplicatedWrite, F_SETNOSIGPIPE, 1) == -1 {
                throw DescriptorSpawnFailure.standardInput
            }
            close(rawDescriptors[0])
            close(rawDescriptors[1])
            return DescriptorPipePair(
                readDescriptor: duplicatedRead,
                writeDescriptor: duplicatedWrite
            )
        } catch {
            close(rawDescriptors[0])
            close(rawDescriptors[1])
            close(duplicatedRead)
            close(duplicatedWrite)
            throw error
        }
    }

    mutating func takeReadDescriptor() -> Int32 {
        let descriptor = readDescriptor
        readDescriptor = -1
        return descriptor
    }

    mutating func takeWriteDescriptor() -> Int32 {
        let descriptor = writeDescriptor
        writeDescriptor = -1
        return descriptor
    }

    mutating func closeBoth() {
        Self.close(readDescriptor)
        Self.close(writeDescriptor)
        readDescriptor = -1
        writeDescriptor = -1
    }

    private static func duplicate(
        _ descriptor: Int32,
        avoiding forbiddenDescriptor: Int32
    ) throws -> Int32 {
        let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
        guard duplicated >= 0 else {
            throw DescriptorSpawnFailure.launch
        }
        guard duplicated == forbiddenDescriptor else {
            return duplicated
        }

        let replacement = fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            forbiddenDescriptor + 1
        )
        close(duplicated)
        guard replacement >= 0 else {
            throw DescriptorSpawnFailure.launch
        }
        return replacement
    }

    private static func close(_ descriptor: Int32) {
        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.close(descriptor)
    }
}

nonisolated private final class DescriptorCStringVector {
    private var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) throws {
        var builtPointers: [UnsafeMutablePointer<CChar>?] = []
        builtPointers.reserveCapacity(strings.count + 1)
        do {
            for string in strings {
                guard !string.utf8.contains(0),
                      let pointer = strdup(string) else {
                    throw DescriptorSpawnFailure.launch
                }
                builtPointers.append(pointer)
            }
            builtPointers.append(nil)
            pointers = builtPointers
        } catch {
            for pointer in builtPointers {
                free(pointer)
            }
            throw error
        }
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func withMutableBuffer<Result>(
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) rethrows -> Result {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
