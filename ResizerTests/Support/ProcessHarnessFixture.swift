import Darwin
import Foundation
@testable import Resizer

final class ProcessHarnessBundleToken: NSObject {}

nonisolated enum ProcessHarnessFixtureError: Error, Sendable, Equatable {
    case executableUnavailable
    case missingResult
    case eventAfterTermination
    case invalidFrame
    case timedOut
}

nonisolated struct CollectedProcess: Sendable {
    let standardOutput: Data
    let standardError: Data
    let result: ProcessResult
    let terminalEventCount: Int
}

nonisolated enum ProcessHarnessEnvironmentValue: Sendable, Equatable {
    case absent
    case value(String)
}

nonisolated enum ProcessHarnessFixture {
    static var executableURL: URL {
        get throws {
            let testBundle = Bundle(for: ProcessHarnessBundleToken.self)
            guard let testExecutableURL = testBundle.executableURL else {
                throw ProcessHarnessFixtureError.executableUnavailable
            }
            let harnessURL = testExecutableURL
                .deletingLastPathComponent()
                .appendingPathComponent("ProcessHarness", isDirectory: false)
            guard FileManager.default.isExecutableFile(atPath: harnessURL.path) else {
                throw ProcessHarnessFixtureError.executableUnavailable
            }
            return harnessURL
        }
    }

    static func request(
        mode: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        diagnosticByteLimit: Int = 64 * 1_024,
        eventBufferCapacity: Int = 256,
        cancellationPolicy: ProcessCancellationPolicy = .signalsOnly,
        id: ProcessExecutionID = ProcessExecutionID()
    ) throws -> ProcessRequest {
        try ProcessRequest(
            id: id,
            executableURL: executableURL,
            arguments: [mode] + arguments,
            environment: environment,
            diagnosticByteLimit: diagnosticByteLimit,
            eventBufferCapacity: eventBufferCapacity,
            cancellationPolicy: cancellationPolicy
        )
    }

    static func collect(
        _ stream: AsyncThrowingStream<ProcessEvent, any Error>,
        observeStandardOutput: @escaping @Sendable (Data) async -> Void = { _ in }
    ) async throws -> CollectedProcess {
        try await withTimeout {
            try await collectWithoutTimeout(
                stream,
                observeStandardOutput: observeStandardOutput
            )
        }
    }

    static func withTimeout<Value: Sendable>(
        after duration: Duration = .seconds(5),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let streamPair = AsyncStream<Result<Value, any Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let operationTask = Task { () -> Void in
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            _ = streamPair.continuation.yield(result)
        }
        let timeoutTask = Task { () -> Void in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            _ = streamPair.continuation.yield(
                .failure(ProcessHarnessFixtureError.timedOut)
            )
        }

        var iterator = streamPair.stream.makeAsyncIterator()
        let result = await iterator.next()
        operationTask.cancel()
        timeoutTask.cancel()
        await operationTask.value
        await timeoutTask.value
        streamPair.continuation.finish()

        guard let result else {
            throw ProcessHarnessFixtureError.timedOut
        }
        return try result.get()
    }

    private static func collectWithoutTimeout(
        _ stream: AsyncThrowingStream<ProcessEvent, any Error>,
        observeStandardOutput: @escaping @Sendable (Data) async -> Void
    ) async throws -> CollectedProcess {
        var standardOutput = Data()
        var standardError = Data()
        var result: ProcessResult?
        var terminalEventCount = 0

        for try await event in stream {
            if result != nil {
                throw ProcessHarnessFixtureError.eventAfterTermination
            }

            switch event {
            case .standardOutput(let data):
                standardOutput.append(data)
                await observeStandardOutput(data)
            case .standardError(let data):
                standardError.append(data)
            case .terminated(let processResult):
                terminalEventCount += 1
                result = processResult
            }
        }

        guard let result else {
            throw ProcessHarnessFixtureError.missingResult
        }
        return CollectedProcess(
            standardOutput: standardOutput,
            standardError: standardError,
            result: result,
            terminalEventCount: terminalEventCount
        )
    }

    static func decodeStringFrames(_ data: Data) throws -> [String] {
        var decoder = FrameDecoder(data: data)
        let count = try decoder.readUInt32()
        var values: [String] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            let valueData = try decoder.readData()
            guard let value = String(data: valueData, encoding: .utf8) else {
                throw ProcessHarnessFixtureError.invalidFrame
            }
            values.append(value)
        }
        try decoder.requireEnd()
        return values
    }

    static func decodeEnvironmentFrames(
        _ data: Data,
        keys: [String]
    ) throws -> [String: ProcessHarnessEnvironmentValue] {
        var decoder = FrameDecoder(data: data)
        let count = try decoder.readUInt32()
        guard count == keys.count else {
            throw ProcessHarnessFixtureError.invalidFrame
        }

        var values: [String: ProcessHarnessEnvironmentValue] = [:]
        for key in keys {
            switch try decoder.readByte() {
            case 0:
                values[key] = .absent
            case 1:
                let valueData = try decoder.readData()
                guard let value = String(data: valueData, encoding: .utf8) else {
                    throw ProcessHarnessFixtureError.invalidFrame
                }
                values[key] = .value(value)
            default:
                throw ProcessHarnessFixtureError.invalidFrame
            }
        }
        try decoder.requireEnd()
        return values
    }

    static func isReaped(_ processIdentifier: Int32) -> Bool {
        errno = 0
        return kill(processIdentifier, 0) == -1 && errno == ESRCH
    }

    static func readyProcessIdentifier(in data: Data) -> Int32? {
        let text = String(decoding: data, as: UTF8.self)
        guard let markerRange = text.range(of: "READY:"),
              let lineEnd = text[markerRange.upperBound...]
                .firstIndex(of: "\n") else {
            return nil
        }
        return Int32(text[markerRange.upperBound..<lineEnd])
    }

    private struct FrameDecoder {
        let bytes: [UInt8]
        var offset = 0

        init(data: Data) {
            bytes = Array(data)
        }

        mutating func readByte() throws -> UInt8 {
            guard offset < bytes.count else {
                throw ProcessHarnessFixtureError.invalidFrame
            }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func readUInt32() throws -> UInt32 {
            guard bytes.count - offset >= 4 else {
                throw ProcessHarnessFixtureError.invalidFrame
            }
            let value = UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
            offset += 4
            return value
        }

        mutating func readData() throws -> Data {
            let length = try readUInt32()
            guard bytes.count - offset >= Int(length) else {
                throw ProcessHarnessFixtureError.invalidFrame
            }
            let end = offset + Int(length)
            defer { offset = end }
            return Data(bytes[offset..<end])
        }

        func requireEnd() throws {
            guard offset == bytes.count else {
                throw ProcessHarnessFixtureError.invalidFrame
            }
        }
    }
}

actor ProcessReadinessProbe {
    private var bytes = Data()
    private var isReady = false
    private var waiter: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    func observe(_ data: Data) {
        bytes.append(data)
        guard !isReady,
              bytes.range(of: Data("READY:".utf8)) != nil else {
            return
        }

        isReady = true
        timeoutTask?.cancel()
        timeoutTask = nil
        waiter?.resume()
        waiter = nil
    }

    func waitUntilReady() async throws {
        if isReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await self?.recordTimeout()
            }
        }
    }

    private func recordTimeout() {
        guard !isReady else {
            return
        }
        waiter?.resume(throwing: ProcessHarnessFixtureError.timedOut)
        waiter = nil
        timeoutTask = nil
    }
}
