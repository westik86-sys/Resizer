import Darwin
import Foundation
import Testing
@testable import Resizer

@Suite("Foundation process runner", .serialized)
struct ProcessRunnerTests {
    @Test("Success emits both pipes and exactly one terminal result")
    func success() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(mode: "success")

        let stream = try await runner.start(request)
        let collected = try await ProcessHarnessFixture.collect(stream)

        #expect(String(decoding: collected.standardOutput, as: UTF8.self) == "stdout:success\n")
        #expect(String(decoding: collected.standardError, as: UTF8.self) == "stderr:success\n")
        #expect(collected.terminalEventCount == 1)
        #expect(collected.result.executionID == request.id)
        #expect(collected.result.termination.status == 0)
        #expect(collected.result.termination.reason == .exit)
        #expect(collected.result.diagnosticTail.data == collected.standardError)
        #expect(!collected.result.diagnosticTail.wasTruncated)
        #expect(!collected.result.wasCancellationRequested)
        #expect(collected.result.lastCancellationStep == nil)
        #expect(ProcessHarnessFixture.isReaped(collected.result.processIdentifier))
        #expect(await runner.activeExecutionCount() == 0)
    }

    @Test("Nonzero exit is a terminal result, not a stream failure")
    func nonzeroExit() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "exit",
            arguments: ["37"]
        )

        let collected = try await ProcessHarnessFixture.collect(
            try await runner.start(request)
        )

        #expect(collected.result.termination.status == 37)
        #expect(collected.result.termination.reason == .exit)
        #expect(collected.terminalEventCount == 1)
        #expect(
            String(decoding: collected.result.diagnosticTail.data, as: UTF8.self)
                == "requested nonzero exit\n"
        )
    }

    @Test("Large simultaneous stdout and stderr never deadlock or lose bytes")
    func largeSimultaneousOutput() async throws {
        let runner = ProcessRunner()
        let byteCount = 2 * 1_024 * 1_024
        let diagnosticLimit = 1_023
        let request = try ProcessHarnessFixture.request(
            mode: "flood",
            arguments: [String(byteCount)],
            diagnosticByteLimit: diagnosticLimit,
            eventBufferCapacity: ProcessRequest.maximumEventBufferCapacity
        )

        let collected = try await ProcessHarnessFixture.collect(
            try await runner.start(request)
        )

        #expect(collected.standardOutput.count == byteCount)
        #expect(collected.standardError.count == byteCount)
        #expect(collected.standardOutput.allSatisfy { $0 == 79 })
        #expect(
            collected.standardError.enumerated().allSatisfy { index, byte in
                byte == UInt8(index % 251)
            }
        )
        #expect(collected.result.termination.status == 0)
        #expect(collected.result.diagnosticTail.byteLimit == diagnosticLimit)
        let tailStart = byteCount - diagnosticLimit
        let expectedTail = Data(
            (tailStart..<byteCount).map { UInt8($0 % 251) }
        )
        #expect(collected.result.diagnosticTail.data == expectedTail)
        #expect(collected.result.diagnosticTail.wasTruncated)
        #expect(collected.terminalEventCount == 1)
    }

    @Test("Arguments and controlled environment remain literal without a shell")
    func literalArgumentsAndEnvironment() async throws {
        let runner = ProcessRunner()
        let canaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResizerCanary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        let arguments = [
            "",
            "two words",
            "single'and\"double",
            "`backticks`",
            "$HOME",
            "$(touch \(canaryURL.path))",
            ";|&<>*?[]",
            "Юникод 🧪",
            "-leading-dash",
            "line one\nline two",
            "back\\slash",
        ]
        let argumentRequest = try ProcessHarnessFixture.request(
            mode: "echo-arguments",
            arguments: arguments
        )
        let argumentRun = try await ProcessHarnessFixture.collect(
            try await runner.start(argumentRequest)
        )

        #expect(
            try ProcessHarnessFixture.decodeStringFrames(
                argumentRun.standardOutput
            ) == arguments
        )
        #expect(!FileManager.default.fileExists(atPath: canaryURL.path))

        let keys = ["RESIZER_VALUE", "LC_ALL", "LANG", "PATH"]
        let environmentRequest = try ProcessHarnessFixture.request(
            mode: "echo-environment",
            arguments: keys,
            environment: ["RESIZER_VALUE": "значение 🧪"]
        )
        let environmentRun = try await ProcessHarnessFixture.collect(
            try await runner.start(environmentRequest)
        )
        let environment = try ProcessHarnessFixture.decodeEnvironmentFrames(
            environmentRun.standardOutput,
            keys: keys
        )

        #expect(environment["RESIZER_VALUE"] == .value("значение 🧪"))
        #expect(environment["LC_ALL"] == .value("C"))
        #expect(environment["LANG"] == .value("C"))
        #expect(environment["PATH"] == .absent)
    }

    @Test("Cancellation can finish through request-provided graceful input")
    func gracefulCancellation() async throws {
        let runner = ProcessRunner()
        let policy = try cancellationPolicy()
        let request = try ProcessHarnessFixture.request(
            mode: "wait-for-q",
            cancellationPolicy: policy
        )

        let collected = try await runAndCancel(
            request: request,
            runner: runner
        )

        #expect(collected.result.termination.status == 0)
        #expect(collected.result.termination.reason == .exit)
        #expect(collected.result.wasCancellationRequested)
        #expect(collected.result.lastCancellationStep == .gracefulInput)
        #expect(collected.terminalEventCount == 1)
        #expect(ProcessHarnessFixture.isReaped(collected.result.processIdentifier))
        #expect(await runner.activeExecutionCount() == 0)
    }

    @Test("Cancellation escalates past ignored interrupt to terminate")
    func terminateFallback() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "ignore-interrupt",
            cancellationPolicy: try cancellationPolicy()
        )

        let collected = try await runAndCancel(
            request: request,
            runner: runner
        )

        #expect(collected.result.termination.reason == .uncaughtSignal)
        #expect(collected.result.termination.status == SIGTERM)
        #expect(collected.result.wasCancellationRequested)
        #expect(collected.result.lastCancellationStep == .terminate)
        #expect(ProcessHarnessFixture.isReaped(collected.result.processIdentifier))
    }

    @Test("Cancellation forces SIGKILL when graceful input and signals are ignored")
    func killFallback() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "ignore-signals",
            cancellationPolicy: try cancellationPolicy()
        )

        let collected = try await runAndCancel(
            request: request,
            runner: runner
        )

        #expect(collected.result.termination.reason == .uncaughtSignal)
        #expect(collected.result.termination.status == SIGKILL)
        #expect(collected.result.wasCancellationRequested)
        #expect(collected.result.lastCancellationStep == .kill)
        #expect(collected.terminalEventCount == 1)
        #expect(ProcessHarnessFixture.isReaped(collected.result.processIdentifier))
        #expect(await runner.activeExecutionCount() == 0)
    }

    @Test("Terminal event waits for process exit and EOF from both pipes")
    func waitsForBothEOFs() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(mode: "delayed-eof")

        let collected = try await ProcessHarnessFixture.collect(
            try await runner.start(request)
        )
        let standardOutput = String(
            decoding: collected.standardOutput,
            as: UTF8.self
        )
        let standardError = String(
            decoding: collected.standardError,
            as: UTF8.self
        )

        #expect(standardOutput.contains("stdout:parent-exit"))
        #expect(standardOutput.contains("stdout:after-parent-exit"))
        #expect(standardError.contains("stderr:parent-exit"))
        #expect(standardError.contains("stderr:after-parent-exit"))
        #expect(collected.result.termination.status == 0)
        #expect(collected.terminalEventCount == 1)
    }

    @Test("Natural exit racing repeated cancellation still finalizes once")
    func naturalExitCancellationRace() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "race-exit",
            cancellationPolicy: try ProcessCancellationPolicy(
                standardInput: .cancellationMessage(Data("q\n".utf8)),
                gracefulInputWait: .milliseconds(500),
                interruptWait: .milliseconds(250),
                terminateWait: .milliseconds(250)
            )
        )
        let readiness = ProcessReadinessProbe()
        let stream = try await runner.start(request)
        let collector = Task {
            try await ProcessHarnessFixture.collect(stream) { data in
                await readiness.observe(data)
            }
        }

        try await readiness.waitUntilReady()
        async let firstCancellation: Void = cancel(
            runner,
            executionID: request.id
        )
        async let repeatedCancellation: Void = cancel(
            runner,
            executionID: request.id
        )
        _ = try await (firstCancellation, repeatedCancellation)
        let collected = try await collector.value

        #expect(collected.result.termination.status == 0)
        #expect(collected.result.termination.reason == .exit)
        #expect(collected.result.wasCancellationRequested)
        #expect(collected.result.lastCancellationStep == .gracefulInput)
        #expect(collected.terminalEventCount == 1)
        #expect(ProcessHarnessFixture.isReaped(collected.result.processIdentifier))
        #expect(await runner.activeExecutionCount() == 0)
    }

    @Test("Cancelling the stream consumer reaps a child after both pipes close")
    func consumerCancellation() async throws {
        var runner: ProcessRunner? = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "close-pipes-wait",
            cancellationPolicy: try ProcessCancellationPolicy(
                standardInput: .closed,
                gracefulInputWait: .zero,
                interruptWait: .milliseconds(50),
                terminateWait: .milliseconds(50)
            )
        )
        let stream = try await runner!.start(request)
        let consumer = Task { () -> Int32? in
            var standardOutput = Data()
            do {
                for try await event in stream {
                    guard case .standardOutput(let data) = event else {
                        continue
                    }
                    standardOutput.append(data)
                    if ProcessHarnessFixture.readyProcessIdentifier(
                        in: standardOutput
                    ) != nil {
                        withUnsafeCurrentTask { task in
                            task?.cancel()
                        }
                    }
                }
            } catch is CancellationError {
                // Expected: cancellation of iteration triggers onTermination.
            } catch {
                return nil
            }
            return ProcessHarnessFixture.readyProcessIdentifier(
                in: standardOutput
            )
        }

        // The runner must retain the live execution after both drain workers
        // reach EOF; only the termination callback can release that ownership.
        runner = nil
        defer { consumer.cancel() }
        let processIdentifier = try await ProcessHarnessFixture.withTimeout {
            await withTaskCancellationHandler {
                await consumer.value
            } onCancel: {
                consumer.cancel()
            }
        }
        let unwrappedProcessIdentifier = try #require(processIdentifier)
        try await waitUntilReaped(unwrappedProcessIdentifier)
        #expect(
            ProcessHarnessFixture.isReaped(unwrappedProcessIdentifier)
        )
    }

    @Test("Finite event buffering fails safely instead of dropping output")
    func eventBufferOverflow() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "success",
            eventBufferCapacity: 1
        )
        let stream = try await runner.start(request)

        try await waitUntilIdle(runner)
        do {
            _ = try await ProcessHarnessFixture.collect(stream)
            Issue.record("Expected the bounded event buffer to overflow")
        } catch let error as ProcessRunnerError {
            #expect(error == .eventBufferOverflow(request.id))
        }

        #expect(await runner.activeExecutionCount() == 0)
    }

    @Test("Duplicate active IDs fail and completed cancellation is a no-op")
    func executionIDLifecycle() async throws {
        let runner = ProcessRunner()
        let request = try ProcessHarnessFixture.request(
            mode: "wait-for-q",
            cancellationPolicy: try cancellationPolicy()
        )
        let readiness = ProcessReadinessProbe()
        let firstStream = try await runner.start(request)
        let collector = Task {
            try await ProcessHarnessFixture.collect(firstStream) { data in
                await readiness.observe(data)
            }
        }

        do {
            _ = try await runner.start(request)
            Issue.record("Expected a duplicate active execution ID to fail")
        } catch let error as ProcessRunnerError {
            #expect(error == .executionIDAlreadyUsed(request.id))
        }

        try await readiness.waitUntilReady()
        try await cancel(runner, executionID: request.id)
        _ = try await collector.value
        try await cancel(runner, executionID: request.id)

        let nextRequest = try ProcessHarnessFixture.request(
            mode: "wait-for-q",
            cancellationPolicy: try cancellationPolicy()
        )
        let nextReadiness = ProcessReadinessProbe()
        let nextStream = try await runner.start(nextRequest)
        let nextCollector = Task {
            try await ProcessHarnessFixture.collect(nextStream) { data in
                await nextReadiness.observe(data)
            }
        }
        try await nextReadiness.waitUntilReady()

        // Give delayed callbacks from the completed execution time to run;
        // they must not affect a new execution with its fresh one-shot ID.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await runner.activeExecutionCount() == 1)
        try await cancel(runner, executionID: nextRequest.id)
        let nextRun = try await nextCollector.value
        #expect(nextRun.result.termination.status == 0)
        #expect(nextRun.result.lastCancellationStep == .gracefulInput)
    }

    @Test("Launch failure leaves no active execution")
    func launchFailure() async throws {
        let runner = ProcessRunner()
        let request = try ProcessRequest(
            executableURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString)"),
            arguments: [],
            environment: [:],
            diagnosticByteLimit: 1_024
        )

        do {
            _ = try await runner.start(request)
            Issue.record("Expected a missing executable to fail at launch")
        } catch let error as ProcessRunnerError {
            #expect(error == .launchFailed(request.id))
        }
        #expect(await runner.activeExecutionCount() == 0)
    }

    private func cancellationPolicy() throws -> ProcessCancellationPolicy {
        try ProcessCancellationPolicy(
            standardInput: .cancellationMessage(Data("q\n".utf8)),
            gracefulInputWait: .milliseconds(250),
            interruptWait: .milliseconds(250),
            terminateWait: .milliseconds(250)
        )
    }

    private func runAndCancel(
        request: ProcessRequest,
        runner: ProcessRunner
    ) async throws -> CollectedProcess {
        let readiness = ProcessReadinessProbe()
        let stream = try await runner.start(request)
        let collector = Task {
            try await ProcessHarnessFixture.collect(stream) { data in
                await readiness.observe(data)
            }
        }

        do {
            try await readiness.waitUntilReady()
        } catch {
            try? await cancel(runner, executionID: request.id)
            _ = try? await collector.value
            throw error
        }

        try await cancel(runner, executionID: request.id)
        return try await collector.value
    }

    private func cancel(
        _ runner: ProcessRunner,
        executionID: ProcessExecutionID
    ) async throws {
        try await ProcessHarnessFixture.withTimeout {
            await runner.cancel(executionID: executionID)
        }
    }

    private func waitUntilIdle(_ runner: ProcessRunner) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await runner.activeExecutionCount() != 0 {
            guard clock.now < deadline else {
                throw ProcessHarnessFixtureError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntilReaped(_ processIdentifier: Int32) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !ProcessHarnessFixture.isReaped(processIdentifier) {
            guard clock.now < deadline else {
                throw ProcessHarnessFixtureError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
