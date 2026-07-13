import Foundation

nonisolated struct TranscodeProgress: Sendable, Equatable {
    let processedMicroseconds: Int64
    let totalMicroseconds: Int64?
    let frame: Int64?
    let framesPerSecond: Double?
    let speed: Double?
    let outputByteCount: Int64?
    let duplicatedFrames: Int64?
    let droppedFrames: Int64?

    init(
        processedMicroseconds: Int64,
        totalMicroseconds: Int64?,
        frame: Int64? = nil,
        framesPerSecond: Double? = nil,
        speed: Double? = nil,
        outputByteCount: Int64? = nil,
        duplicatedFrames: Int64? = nil,
        droppedFrames: Int64? = nil
    ) throws {
        guard processedMicroseconds >= 0,
              totalMicroseconds.map({ $0 >= 0 }) ?? true,
              frame.map({ $0 >= 0 }) ?? true,
              framesPerSecond.map({ $0.isFinite && $0 >= 0 }) ?? true,
              speed.map({ $0.isFinite && $0 >= 0 }) ?? true,
              outputByteCount.map({ $0 >= 0 }) ?? true,
              duplicatedFrames.map({ $0 >= 0 }) ?? true,
              droppedFrames.map({ $0 >= 0 }) ?? true else {
            throw TranscodeProgressValidationError.invalidMetric
        }

        self.processedMicroseconds = processedMicroseconds
        self.totalMicroseconds = totalMicroseconds
        self.frame = frame
        self.framesPerSecond = framesPerSecond
        self.speed = speed
        self.outputByteCount = outputByteCount
        self.duplicatedFrames = duplicatedFrames
        self.droppedFrames = droppedFrames
    }

    var fractionCompleted: Double? {
        guard let totalMicroseconds, totalMicroseconds > 0 else {
            return nil
        }

        let fraction = Double(processedMicroseconds) / Double(totalMicroseconds)
        return min(max(fraction, 0), 1)
    }
}

nonisolated enum TranscodeProgressValidationError: Error, Sendable, Equatable {
    case invalidMetric
}

nonisolated struct CompressionResult: Sendable, Equatable {
    let outputURL: URL
    let outputByteCount: Int64
    let elapsed: Duration

    init(
        outputURL: URL,
        outputByteCount: Int64,
        elapsed: Duration
    ) throws {
        guard outputURL.isFileURL,
              outputByteCount > 0,
              elapsed >= .zero else {
            throw CompressionResultValidationError.invalidResult
        }

        self.outputURL = outputURL
        self.outputByteCount = outputByteCount
        self.elapsed = elapsed
    }
}

nonisolated enum CompressionResultValidationError: Error, Sendable, Equatable {
    case invalidResult
}

nonisolated struct TranscodeFailure: Error, Sendable, Equatable {
    let stage: FailureStage
    let reason: FailureReason
    let diagnosticTail: BoundedDiagnostic?

    var retryTarget: RetryTarget {
        switch stage {
        case .probe:
            .probing
        case .preflight, .encode, .validate, .commit:
            .ready
        }
    }
}

nonisolated struct BoundedDiagnostic: Sendable, Equatable {
    let text: String
    let utf8ByteLimit: Int
    let wasTruncated: Bool

    init(
        text: String,
        utf8ByteLimit: Int,
        wasTruncated: Bool
    ) throws {
        guard utf8ByteLimit > 0,
              text.utf8.count <= utf8ByteLimit else {
            throw TranscodeFailureValidationError.invalidDiagnostic
        }
        self.text = text
        self.utf8ByteLimit = utf8ByteLimit
        self.wasTruncated = wasTruncated
    }
}

nonisolated enum TranscodeFailureValidationError: Error, Sendable, Equatable {
    case invalidDiagnostic
}

nonisolated enum FailureStage: Sendable, Equatable {
    case probe
    case preflight
    case encode
    case validate
    case commit
}

nonisolated enum FailureReason: Sendable, Equatable {
    case serviceUnavailable
    case invalidMedia
    case processFailed(exitCode: Int32?)
    case fileSystem
    case unknown
}
