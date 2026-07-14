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

/// Stable, path-free identifiers for infrastructure failures that do not have
/// an FFmpeg stderr tail. Keep this closed and typed so diagnostics cannot
/// accidentally expose an underlying error description or selected URL.
nonisolated enum FailureTechnicalCode: String, Sendable, Equatable {
    case processExecutionIDAlreadyUsed = "process_execution_id_already_used"
    case processStandardInputConfigurationFailed =
        "process_standard_input_configuration_failed"
    case processStandardOutputConfigurationFailed =
        "process_standard_output_configuration_failed"
    case processLaunchFailed = "process_launch_failed"
    case processStandardOutputReadFailed =
        "process_standard_output_read_failed"
    case processStandardErrorReadFailed =
        "process_standard_error_read_failed"
    case processEventBufferOverflow = "process_event_buffer_overflow"
    case transcoderExecutableUnavailable =
        "transcoder_executable_unavailable"
    case transcoderExecutableInvalid = "transcoder_executable_invalid"
    case transcoderDuplicateJob = "transcoder_duplicate_job"
    case transcoderInvalidProcessRequest =
        "transcoder_invalid_process_request"
    case transcoderInvalidTemporaryReservation =
        "transcoder_invalid_temporary_reservation"
    case transcoderInvalidProcessEventSequence =
        "transcoder_invalid_process_event_sequence"
    case transcoderProgressProtocolError =
        "transcoder_progress_protocol_error"
    case transcoderTemporaryOutputMissing =
        "transcoder_temporary_output_missing"
    case transcoderTemporaryOutputInvalid =
        "transcoder_temporary_output_invalid"
}

nonisolated struct TranscodeFailure: Error, Sendable, Equatable {
    let stage: FailureStage
    let reason: FailureReason
    let diagnosticTail: BoundedDiagnostic?
    let technicalCode: FailureTechnicalCode?

    init(
        stage: FailureStage,
        reason: FailureReason,
        diagnosticTail: BoundedDiagnostic?,
        technicalCode: FailureTechnicalCode? = nil
    ) {
        self.stage = stage
        self.reason = reason
        self.diagnosticTail = diagnosticTail
        self.technicalCode = technicalCode
    }

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
    case inputUnavailable
    case outputUnavailable
    case outputConflict
    case unsupportedOutputFileSystem
    case insufficientStorage
    case processFailed(exitCode: Int32?)
    case fileSystem
    case unknown

    var isFileSystemRelated: Bool {
        switch self {
        case .inputUnavailable, .outputUnavailable, .outputConflict,
             .unsupportedOutputFileSystem, .insufficientStorage,
             .fileSystem:
            true
        case .serviceUnavailable, .invalidMedia, .processFailed, .unknown:
            false
        }
    }
}
