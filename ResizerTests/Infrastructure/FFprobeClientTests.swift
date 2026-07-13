import Foundation
import Testing
@testable import Resizer

@Suite("FFprobe client")
struct FFprobeClientTests {
    @Test("Builds exact arguments and keeps a special-character path literal")
    func exactArgumentsAndLiteralSourcePath() async throws {
        let sourceURL = URL(
            fileURLWithPath:
                "/tmp/Видео 🧪 $HOME;$(touch nope) [one] 'quoted' \\ file.mov"
        )
        let runner = FFprobeProcessRunnerStub(
            script: try .success(standardOutputChunks: [Self.validJSON])
        )
        let executableURL = URL(
            fileURLWithPath: "/Applications/Resizer Test.app/Contents/MacOS/ffprobe"
        )
        let client = try FFprobeClient(
            executableURL: executableURL,
            processRunner: runner
        )

        _ = try await client.probe(sourceURL)

        let requests = await runner.recordedRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.executableURL == executableURL.standardizedFileURL)
        #expect(
            request.arguments == [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                sourceURL.path,
            ]
        )
        #expect(request.arguments.last == sourceURL.path)
        #expect(request.environment == ["LC_ALL": "C", "LANG": "C"])
        #expect(request.diagnosticByteLimit == 256 * 1_024)
        #expect(
            request.eventBufferCapacity
                == ProcessRequest.maximumEventBufferCapacity
        )
        #expect(request.cancellationPolicy == .signalsOnly)
        #expect(await runner.recordedCancellationRequests().isEmpty)
    }

    @Test("Collects JSON split at arbitrary byte boundaries")
    func chunkedStandardOutput() async throws {
        let chunks = Self.validJSON.map { Data([$0]) }
        let runner = FFprobeProcessRunnerStub(
            script: try .success(standardOutputChunks: chunks)
        )
        let client = try makeClient(runner: runner)

        let mediaInfo = try await client.probe(Self.sourceURL)

        #expect(mediaInfo.formatNames == ["mov", "mp4"])
        #expect(mediaInfo.durationMicroseconds == 1_250_001)
        #expect(mediaInfo.byteCount == 42)
        #expect(mediaInfo.bitRate == 336)
        #expect(mediaInfo.streams.isEmpty)
    }

    @Test("Reports a nonzero exit as a typed process failure")
    func nonzeroExit() async throws {
        let diagnostic = Data("decoder failed\n".utf8)
        let termination = try FFprobeRunnerTermination(
            status: 23,
            reason: .exit,
            diagnosticData: diagnostic,
            diagnosticByteLimit: diagnostic.count
        )
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [
                    .standardOutput(Self.validJSON),
                    .standardError(diagnostic),
                    .terminated(termination),
                ]
            )
        )
        let client = try makeClient(runner: runner)

        do {
            _ = try await client.probe(Self.sourceURL)
            Issue.record("Expected a typed nonzero-exit failure")
        } catch let error as FFprobeClientError {
            #expect(
                error == .processFailed(
                    termination: ProcessTerminationStatus(
                        status: 23,
                        reason: .exit
                    ),
                    diagnosticTail: termination.diagnosticTail
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Reports signal termination as a typed process failure")
    func signalTermination() async throws {
        let diagnostic = Data("terminated by signal\n".utf8)
        let termination = try FFprobeRunnerTermination(
            status: 15,
            reason: .uncaughtSignal,
            diagnosticData: diagnostic,
            diagnosticByteLimit: diagnostic.count
        )
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [
                    .standardOutput(Self.validJSON),
                    .terminated(termination),
                ]
            )
        )
        let client = try makeClient(runner: runner)

        do {
            _ = try await client.probe(Self.sourceURL)
            Issue.record("Expected a typed signal-termination failure")
        } catch let error as FFprobeClientError {
            #expect(
                error == .processFailed(
                    termination: ProcessTerminationStatus(
                        status: 15,
                        reason: .uncaughtSignal
                    ),
                    diagnosticTail: termination.diagnosticTail
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Accepts stdout exactly at the configured byte cap")
    func outputAtCapBoundary() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: try .success(standardOutputChunks: [Self.validJSON])
        )
        let client = try makeClient(
            runner: runner,
            maximumOutputByteCount: Self.validJSON.count
        )

        let mediaInfo = try await client.probe(Self.sourceURL)

        #expect(mediaInfo.byteCount == 42)
        #expect(await runner.recordedCancellationRequests().isEmpty)
    }

    @Test("Cancels and reports stdout one byte over the configured cap")
    func outputOverCap() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: try .success(standardOutputChunks: [Self.validJSON])
        )
        let limit = Self.validJSON.count - 1
        let client = try makeClient(
            runner: runner,
            maximumOutputByteCount: limit
        )

        do {
            _ = try await client.probe(Self.sourceURL)
            Issue.record("Expected bounded stdout to reject overflow")
        } catch let error as FFprobeClientError {
            #expect(error == .outputTooLarge(limit: limit))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let requests = await runner.recordedRequests()
        let request = try #require(requests.first)
        let cancellations = await runner.recordedCancellationRequests()
        #expect(!cancellations.isEmpty)
        #expect(cancellations.allSatisfy { $0 == request.id })
    }

    @Test("Rejects a stream that finishes without a terminal result")
    func missingTerminalResult() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [.standardOutput(Self.validJSON)]
            )
        )
        let client = try makeClient(runner: runner)

        await expectInvalidEventSequence(client: client)
    }

    @Test("Rejects output emitted after the terminal result")
    func eventAfterTerminalResult() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [
                    .terminated(try FFprobeRunnerTermination()),
                    .standardOutput(Self.validJSON),
                ]
            )
        )
        let client = try makeClient(runner: runner)

        await expectInvalidEventSequence(client: client)
    }

    @Test("Rejects a terminal result for a different execution")
    func mismatchedTerminalExecutionID() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [
                    .standardOutput(Self.validJSON),
                    .terminated(
                        try FFprobeRunnerTermination(
                            executionID: ProcessExecutionID()
                        )
                    ),
                ]
            )
        )
        let client = try makeClient(runner: runner)

        await expectInvalidEventSequence(client: client)
    }

    @Test("Task cancellation does not return before runner cancellation finishes")
    func taskCancellationAwaitsRunner() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: FFprobeRunnerScript(
                instructions: [],
                ending: .holdOpen
            ),
            blocksCancellation: true
        )
        let client = try makeClient(runner: runner)
        let completion = FFprobeOperationCompletionProbe()
        let operation = Task {
            do {
                let value = try await client.probe(Self.sourceURL)
                await completion.markFinished()
                return value
            } catch {
                await completion.markFinished()
                throw error
            }
        }

        do {
            try await waitUntil {
                await runner.recordedRequests().count == 1
            }
            operation.cancel()
            try await waitUntil {
                !(await runner.recordedCancellationRequests().isEmpty)
            }
            try await Task.sleep(for: .milliseconds(25))
            #expect(!(await completion.isFinished))
        } catch {
            await runner.releaseCancellation()
            _ = try? await operation.value
            throw error
        }

        await runner.releaseCancellation()
        do {
            _ = try await operation.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected after runner-owned teardown has been released.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await completion.isFinished)
    }

    @Test("Bundled construction locates app ffprobe while using injected runner")
    func bundledExecutableWithInjectedRunner() async throws {
        let runner = FFprobeProcessRunnerStub(
            script: try .success(standardOutputChunks: [Self.validJSON])
        )
        let expectedExecutable = try #require(
            Bundle.main.url(forAuxiliaryExecutable: "ffprobe")?
                .resolvingSymlinksInPath()
                .standardizedFileURL
        )
        let client = try FFprobeClient.bundled(processRunner: runner)

        _ = try await client.probe(Self.sourceURL)

        let requests = await runner.recordedRequests()
        let request = try #require(requests.first)
        let bundlePath = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        #expect(request.executableURL == expectedExecutable)
        #expect(request.executableURL.path.hasPrefix(bundlePath + "/"))
        #expect(
            FileManager.default.isExecutableFile(
                atPath: request.executableURL.path
            )
        )
    }

    private static let sourceURL = URL(
        fileURLWithPath: "/tmp/FFprobeClientTests/input.mov"
    )

    private static let validJSON = Data(
        #"{"streams":[],"format":{"format_name":"mov,mp4","duration":"1.250001","size":"42","bit_rate":"336"},"unknown":"🧪"}"#.utf8
    )

    private func makeClient(
        runner: any ProcessRunning,
        maximumOutputByteCount: Int = FFprobeClient.defaultMaximumOutputByteCount
    ) throws -> FFprobeClient {
        try FFprobeClient(
            executableURL: URL(fileURLWithPath: "/test/bin/ffprobe"),
            processRunner: runner,
            maximumOutputByteCount: maximumOutputByteCount
        )
    }

    private func expectInvalidEventSequence(
        client: FFprobeClient
    ) async {
        do {
            _ = try await client.probe(Self.sourceURL)
            Issue.record("Expected an invalid process event sequence")
        } catch let error as FFprobeClientError {
            #expect(error == .invalidProcessEventSequence)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                throw ProcessHarnessFixtureError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
