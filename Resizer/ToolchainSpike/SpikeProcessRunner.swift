import Foundation

nonisolated struct BoundedCapture: Sendable {
    let data: Data
    let wasTruncated: Bool
}

nonisolated struct ProcessTermination: Sendable {
    let status: Int32
    let reason: Process.TerminationReason
}

nonisolated struct SpikeProcessResult: Sendable {
    let termination: ProcessTermination
    let standardOutput: BoundedCapture
    let standardError: BoundedCapture
}

nonisolated enum SpikeProcessRunnerError: Error, Sendable {
    case invalidCaptureLimit
}

actor SpikeProcessRunner {
    func run(
        executableURL: URL,
        arguments: [String],
        standardOutputLimit: Int = 2 * 1_024 * 1_024,
        standardErrorLimit: Int = 1_024 * 1_024
    ) async throws -> SpikeProcessResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            throw SpikeProcessRunnerError.invalidCaptureLimit
        }

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "LC_ALL": "C",
            "LANG": "C",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            throw error
        }

        // The child inherited its descriptors. Close only the parent's writer
        // copies so both readers observe EOF after the child exits.
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()

        async let standardOutput = Self.capturePrefix(
            from: standardOutputPipe.fileHandleForReading,
            limit: standardOutputLimit
        )
        async let standardError = Self.captureTail(
            from: standardErrorPipe.fileHandleForReading,
            limit: standardErrorLimit
        )

        let termination = await Self.waitForTermination(of: process)
        let captures = try await (standardOutput, standardError)

        return SpikeProcessResult(
            termination: termination,
            standardOutput: captures.0,
            standardError: captures.1
        )
    }

    private nonisolated static func waitForTermination(
        of process: Process
    ) async -> ProcessTermination {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(
                    returning: ProcessTermination(
                        status: terminatedProcess.terminationStatus,
                        reason: terminatedProcess.terminationReason
                    )
                )
            }
        }
    }

    private nonisolated static func capturePrefix(
        from handle: FileHandle,
        limit: Int
    ) async throws -> BoundedCapture {
        defer { try? handle.close() }

        var retained = Data()
        retained.reserveCapacity(limit)
        var wasTruncated = false

        // Continue draining after the retention limit to avoid blocking the
        // child on a full pipe.
        for try await byte in handle.bytes {
            if retained.count < limit {
                retained.append(byte)
            } else {
                wasTruncated = true
            }
        }

        return BoundedCapture(data: retained, wasTruncated: wasTruncated)
    }

    private nonisolated static func captureTail(
        from handle: FileHandle,
        limit: Int
    ) async throws -> BoundedCapture {
        defer { try? handle.close() }

        guard limit > 0 else {
            var receivedAnyByte = false
            for try await _ in handle.bytes {
                receivedAnyByte = true
            }
            return BoundedCapture(
                data: Data(),
                wasTruncated: receivedAnyByte
            )
        }

        var ring = [UInt8](repeating: 0, count: limit)
        var retainedCount = 0
        var nextReplacementIndex = 0
        var wasTruncated = false

        for try await byte in handle.bytes {
            if retainedCount < limit {
                ring[retainedCount] = byte
                retainedCount += 1
            } else {
                ring[nextReplacementIndex] = byte
                nextReplacementIndex = (nextReplacementIndex + 1) % limit
                wasTruncated = true
            }
        }

        let retained: [UInt8]
        if wasTruncated {
            retained = Array(ring[nextReplacementIndex...])
                + Array(ring[..<nextReplacementIndex])
        } else {
            retained = Array(ring.prefix(retainedCount))
        }

        return BoundedCapture(
            data: Data(retained),
            wasTruncated: wasTruncated
        )
    }
}
