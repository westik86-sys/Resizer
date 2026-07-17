import Foundation

nonisolated struct FFmpegCapabilities: Sendable, Equatable {
    let decoders: Set<String>
    let encoders: Set<String>
    let filters: Set<String>
    let demuxers: Set<String>
    let muxers: Set<String>
    let inputProtocols: Set<String>
    let outputProtocols: Set<String>
}

nonisolated protocol FFmpegCapabilityProviding: Sendable {
    func capabilities() async throws -> FFmpegCapabilities
}

nonisolated enum FFmpegCapabilityCategory: Sendable, Equatable {
    case decoder
    case encoder
    case filter
    case demuxer
    case muxer
    case inputProtocol
    case outputProtocol
}

nonisolated enum FFmpegPreflightError: Error, Sendable, Equatable {
    case unavailableCapability(
        category: FFmpegCapabilityCategory,
        name: String
    )
    case unsupportedInputFormat([String])
    case missingVideoStream
    case missingCodecName(streamIndex: Int)
    case unsupportedDecoder(streamIndex: Int, codecName: String)
    case unverifiedLibx264PixelFormat(OutputPixelFormat)
}

/// Compile-time half of the audited bundled-encoder contract. The release
/// build records the same identifier only after real per-architecture encode
/// smoke tests pass; runtime discovery requires that exact identifier in the
/// bundled FFmpeg version as well as the libx264 encoder. Encoder help is not
/// trusted as pixel-format proof because it can over-report an external build.
nonisolated enum BundledFFmpegProfile {
    static let identifier = "libx264-8-and-10-bit-all-chroma-v1"
    static let verifiedLibx264PixelFormats: Set<OutputPixelFormat> = [
        .yuv420p,
        .yuv420p10le,
        .yuv422p10le,
        .yuv444p10le,
    ]
}

nonisolated enum FFmpegCapabilityClientError: Error, Sendable, Equatable {
    case invalidExecutableURL
    case invalidConfiguration
    case discoveryTimedOut
    case invalidProcessEventSequence
    case invalidCapabilityOutput
    case incompatibleBundledProfile(expectedIdentifier: String)
    case outputTooLarge(limit: Int)
    case processFailed(
        termination: ProcessTerminationStatus,
        diagnosticTail: BoundedData
    )
}

nonisolated struct FixedFFmpegCapabilityProvider: FFmpegCapabilityProviding {
    let value: FFmpegCapabilities

    func capabilities() async throws -> FFmpegCapabilities {
        value
    }
}

actor FFmpegCapabilityClient: FFmpegCapabilityProviding {
    static let maximumOutputByteCount = 1 * 1_024 * 1_024
    static let defaultDiscoveryTimeout: Duration = .seconds(15)

    private static let diagnosticByteLimit = 128 * 1_024

    private nonisolated enum QueryKind: CaseIterable, Hashable, Sendable {
        case version
        case decoders
        case encoders
        case filters
        case demuxers
        case muxers
        case protocols

        var option: String {
            switch self {
            case .version:
                "-version"
            case .decoders:
                "-decoders"
            case .encoders:
                "-encoders"
            case .filters:
                "-filters"
            case .demuxers:
                "-demuxers"
            case .muxers:
                "-muxers"
            case .protocols:
                "-protocols"
            }
        }

    }

    private nonisolated enum DiscoveryEvent: Sendable {
        case query(QueryKind, Data)
        case timeout
    }

    private nonisolated struct InFlightDiscovery: Sendable {
        let id: UUID
        let task: Task<FFmpegCapabilities, any Error>
        var waiters: [UUID: DiscoveryWaiter]
    }

    private nonisolated struct DiscoveryWaiter: Sendable {
        let continuation: CheckedContinuation<
            FFmpegCapabilities,
            any Error
        >
    }

    private let executableURL: URL
    private let processRunner: any ProcessRunning
    private let discoveryTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cachedCapabilities: FFmpegCapabilities?
    private var inFlightDiscovery: InFlightDiscovery?

    init(
        executableURL: URL,
        processRunner: any ProcessRunning,
        discoveryTimeout: Duration = FFmpegCapabilityClient
            .defaultDiscoveryTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            duration in
            try await Task.sleep(for: duration)
        }
    ) throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0") else {
            throw FFmpegCapabilityClientError.invalidExecutableURL
        }
        guard discoveryTimeout > .zero else {
            throw FFmpegCapabilityClientError.invalidConfiguration
        }
        self.executableURL = executableURL.standardizedFileURL
        self.processRunner = processRunner
        self.discoveryTimeout = discoveryTimeout
        self.sleep = sleep
    }

    func capabilities() async throws -> FFmpegCapabilities {
        try Task.checkCancellation()
        if let cachedCapabilities {
            return cachedCapabilities
        }

        let waiterID = UUID()
        let discoveryID: UUID
        if let existing = inFlightDiscovery {
            discoveryID = existing.id
        } else {
            discoveryID = UUID()
            let task = Task { [self] in
                try await discoverCapabilities()
            }
            inFlightDiscovery = InFlightDiscovery(
                id: discoveryID,
                task: task,
                waiters: [:]
            )
            Task { [self] in
                do {
                    let value = try await task.value
                    finishDiscovery(
                        id: discoveryID,
                        result: .success(value)
                    )
                } catch {
                    finishDiscovery(
                        id: discoveryID,
                        result: .failure(error)
                    )
                }
            }
        }

        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation {
                continuation in
                registerWaiter(
                    DiscoveryWaiter(continuation: continuation),
                    waiterID: waiterID,
                    discoveryID: discoveryID
                )
            }
            try Task.checkCancellation()
            return value
        } onCancel: { [self] in
            Task {
                await cancelWaiter(
                    waiterID,
                    discoveryID: discoveryID
                )
            }
        }
    }

    private func registerWaiter(
        _ waiter: DiscoveryWaiter,
        waiterID: UUID,
        discoveryID: UUID
    ) {
        guard var discovery = inFlightDiscovery,
              discovery.id == discoveryID else {
            waiter.continuation.resume(
                throwing: FFmpegCapabilityClientError
                    .invalidProcessEventSequence
            )
            return
        }
        discovery.waiters[waiterID] = waiter
        inFlightDiscovery = discovery
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        discoveryID: UUID
    ) async {
        guard var discovery = inFlightDiscovery,
              discovery.id == discoveryID else {
            return
        }
        guard let waiter = discovery.waiters.removeValue(
            forKey: waiterID
        ) else {
            return
        }
        if discovery.waiters.isEmpty {
            // Detach the cancelled generation before teardown awaits runner
            // EOF so a new caller never joins a doomed discovery task.
            inFlightDiscovery = nil
            discovery.task.cancel()

            // Keep the final caller suspended until every structured query
            // task has completed its ProcessRunner cancellation and pipe
            // drain. The coordinator's workflow/shutdown barrier can then
            // rely on this call returning only after no discovery children
            // remain.
            _ = await discovery.task.result
        } else {
            inFlightDiscovery = discovery
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishDiscovery(
        id: UUID,
        result: Result<FFmpegCapabilities, any Error>
    ) {
        guard let discovery = inFlightDiscovery,
              discovery.id == id else {
            return
        }
        inFlightDiscovery = nil

        switch result {
        case .success(let value):
            cachedCapabilities = value
            for waiter in discovery.waiters.values {
                waiter.continuation.resume(returning: value)
            }
        case .failure(let error):
            for waiter in discovery.waiters.values {
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func discoverCapabilities() async throws -> FFmpegCapabilities {
        try await withThrowingTaskGroup(
            of: DiscoveryEvent.self,
            returning: FFmpegCapabilities.self
        ) { group in
            for kind in QueryKind.allCases {
                group.addTask { [self] in
                    .query(kind, try await query(kind.option))
                }
            }
            let timeout = discoveryTimeout
            let sleep = sleep
            group.addTask {
                try await sleep(timeout)
                return .timeout
            }
            defer { group.cancelAll() }

            var results: [QueryKind: Data] = [:]
            while let event = try await group.next() {
                switch event {
                case .timeout:
                    throw FFmpegCapabilityClientError.discoveryTimedOut
                case .query(let kind, let data):
                    results[kind] = data
                }

                if results.count == QueryKind.allCases.count {
                    return try FFmpegCapabilityParser().parse(
                        version: try required(.version, in: results),
                        decoders: try required(.decoders, in: results),
                        encoders: try required(.encoders, in: results),
                        filters: try required(.filters, in: results),
                        demuxers: try required(.demuxers, in: results),
                        muxers: try required(.muxers, in: results),
                        protocols: try required(.protocols, in: results)
                    )
                }
            }
            throw FFmpegCapabilityClientError.invalidProcessEventSequence
        }
    }

    private func required(
        _ kind: QueryKind,
        in results: [QueryKind: Data]
    ) throws -> Data {
        guard let value = results[kind] else {
            throw FFmpegCapabilityClientError.invalidProcessEventSequence
        }
        return value
    }

    private func query(_ option: String) async throws -> Data {
        try Task.checkCancellation()
        let request = try ProcessRequest(
            executableURL: executableURL,
            arguments: ["-hide_banner", option],
            environment: [:],
            diagnosticByteLimit: Self.diagnosticByteLimit,
            eventBufferCapacity: 256,
            cancellationPolicy: .signalsOnly
        )

        return try await withTaskCancellationHandler {
            do {
                let stream = try await processRunner.start(request)
                try Task.checkCancellation()
                return try await collect(
                    stream,
                    executionID: request.id
                )
            } catch is CancellationError {
                await cancelAndWait(executionID: request.id)
                throw CancellationError()
            } catch {
                await cancelAndWait(executionID: request.id)
                throw error
            }
        } onCancel: {
            Task {
                await processRunner.cancel(executionID: request.id)
            }
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProcessEvent, any Error>,
        executionID: ProcessExecutionID
    ) async throws -> Data {
        var standardOutput = Data()
        var result: ProcessResult?
        var outputWasTooLarge = false
        var cancellationTask: Task<Void, Never>?

        for try await event in stream {
            guard result == nil else {
                throw FFmpegCapabilityClientError.invalidProcessEventSequence
            }

            switch event {
            case .standardOutput(let data):
                guard !outputWasTooLarge else { continue }
                guard data.count <= Self.maximumOutputByteCount
                    - standardOutput.count else {
                    outputWasTooLarge = true
                    cancellationTask = Task.detached { [processRunner] in
                        await processRunner.cancel(executionID: executionID)
                    }
                    continue
                }
                standardOutput.append(data)
            case .standardError:
                break
            case .terminated(let processResult):
                guard processResult.executionID == executionID else {
                    throw FFmpegCapabilityClientError
                        .invalidProcessEventSequence
                }
                result = processResult
            }
        }

        await cancellationTask?.value
        try Task.checkCancellation()
        if outputWasTooLarge {
            throw FFmpegCapabilityClientError.outputTooLarge(
                limit: Self.maximumOutputByteCount
            )
        }
        guard let result else {
            throw FFmpegCapabilityClientError.invalidProcessEventSequence
        }
        guard result.termination.reason == .exit,
              result.termination.status == 0 else {
            throw FFmpegCapabilityClientError.processFailed(
                termination: result.termination,
                diagnosticTail: result.diagnosticTail
            )
        }
        return standardOutput
    }

    private func cancelAndWait(executionID: ProcessExecutionID) async {
        let cleanupTask = Task.detached { [processRunner] in
            await processRunner.cancel(executionID: executionID)
        }
        await cleanupTask.value
    }
}

nonisolated struct FFmpegCapabilityParser: Sendable {
    func parse(
        version: Data,
        decoders: Data,
        encoders: Data,
        filters: Data,
        demuxers: Data,
        muxers: Data,
        protocols: Data
    ) throws -> FFmpegCapabilities {
        guard let versionText = String(data: version, encoding: .utf8),
              let decoderText = String(data: decoders, encoding: .utf8),
              let encoderText = String(data: encoders, encoding: .utf8),
              let filterText = String(data: filters, encoding: .utf8),
              let demuxerText = String(data: demuxers, encoding: .utf8),
              let muxerText = String(data: muxers, encoding: .utf8),
              let protocolText = String(data: protocols, encoding: .utf8)
        else {
            throw FFmpegCapabilityClientError.invalidCapabilityOutput
        }

        try validateBundledProfile(versionText)

        let parsedProtocols = parseProtocols(protocolText)
        let value = FFmpegCapabilities(
            decoders: parseFlagTable(decoderText),
            encoders: parseFlagTable(encoderText),
            filters: parseFlagTable(filterText),
            demuxers: parseFormatTable(demuxerText),
            muxers: parseFormatTable(muxerText),
            inputProtocols: parsedProtocols.input,
            outputProtocols: parsedProtocols.output
        )
        guard !value.decoders.isEmpty,
              !value.encoders.isEmpty,
              !value.filters.isEmpty,
              !value.demuxers.isEmpty,
              !value.muxers.isEmpty,
              !value.inputProtocols.isEmpty,
              !value.outputProtocols.isEmpty else {
            throw FFmpegCapabilityClientError.invalidCapabilityOutput
        }
        return value
    }

    private func validateBundledProfile(_ text: String) throws {
        guard let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first else {
            throw FFmpegCapabilityClientError.invalidCapabilityOutput
        }
        let fields = firstLine.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3,
              fields[0] == "ffmpeg",
              fields[1] == "version" else {
            throw FFmpegCapabilityClientError.invalidCapabilityOutput
        }

        let versionToken = fields[2]
        let requiredSuffix = "-\(BundledFFmpegProfile.identifier)"
        guard versionToken.hasSuffix(requiredSuffix),
              versionToken.count > requiredSuffix.count else {
            throw FFmpegCapabilityClientError.incompatibleBundledProfile(
                expectedIdentifier: BundledFFmpegProfile.identifier
            )
        }
    }

    private func parseFlagTable(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] != "=" else { return nil }
            let flags = fields[0]
            guard flags.allSatisfy({ $0 == "." || $0.isLetter }) else {
                return nil
            }
            return String(fields[1])
        })
    }

    private func parseFormatTable(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).flatMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] != "=" else {
                return [String]()
            }
            let flags = fields[0]
            guard flags.allSatisfy({ $0 == "." || $0.isLetter }),
                  flags.contains("D") || flags.contains("E") else {
                return [String]()
            }
            return fields[1].split(separator: ",").map(String.init)
        })
    }

    private func parseProtocols(
        _ text: String
    ) -> (input: Set<String>, output: Set<String>) {
        enum Section {
            case none
            case input
            case output
        }

        var section = Section.none
        var input = Set<String>()
        var output = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            switch line {
            case "Input:":
                section = .input
            case "Output:":
                section = .output
            default:
                guard !line.isEmpty,
                      !line.contains(" "),
                      !line.hasSuffix(":") else {
                    continue
                }
                switch section {
                case .none:
                    break
                case .input:
                    input.insert(line)
                case .output:
                    output.insert(line)
                }
            }
        }
        return (input, output)
    }
}

nonisolated struct FFmpegPreflightValidator: Sendable {
    private let verifiedLibx264PixelFormats: Set<OutputPixelFormat>

    init(
        verifiedLibx264PixelFormats: Set<OutputPixelFormat> =
            BundledFFmpegProfile.verifiedLibx264PixelFormats
    ) {
        self.verifiedLibx264PixelFormats = verifiedLibx264PixelFormats
    }

    func validate(
        _ request: TranscodeRequest,
        capabilities: FFmpegCapabilities
    ) throws {
        try validate(
            mediaInfo: request.mediaInfo,
            recipe: request.recipe,
            capabilities: capabilities
        )
    }

    func validate(
        mediaInfo: MediaInfo,
        recipe: CompressionRecipe,
        capabilities: FFmpegCapabilities
    ) throws {
        let inputFormats = Set(mediaInfo.formatNames.map {
            $0.lowercased()
        })
        guard !inputFormats.isDisjoint(with: capabilities.demuxers) else {
            throw FFmpegPreflightError.unsupportedInputFormat(
                mediaInfo.formatNames
            )
        }

        let videos = mediaInfo.videoStreams.filter {
            !$0.disposition.isAttachedPicture
        }
        guard let video = preferredVideo(videos) else {
            throw FFmpegPreflightError.missingVideoStream
        }
        try requireDecoder(
            codecName: video.codecName,
            streamIndex: video.index,
            capabilities: capabilities
        )

        let encoder = switch recipe.videoCodec {
        case .h264Libx264:
            "libx264"
        }
        try require(encoder, in: capabilities.encoders, category: .encoder)
        guard verifiedLibx264PixelFormats.contains(
            recipe.outputPixelFormat
        ) else {
            throw FFmpegPreflightError.unverifiedLibx264PixelFormat(
                recipe.outputPixelFormat
            )
        }
        try require("scale", in: capabilities.filters, category: .filter)
        try require("mp4", in: capabilities.muxers, category: .muxer)
        try require(
            "file",
            in: capabilities.inputProtocols,
            category: .inputProtocol
        )
        try require(
            "fd",
            in: capabilities.outputProtocols,
            category: .outputProtocol
        )
        try require(
            "pipe",
            in: capabilities.outputProtocols,
            category: .outputProtocol
        )

        if case .aac = recipe.audioPolicy,
           let audio = mediaInfo.preferredAudioStream {
            try requireDecoder(
                codecName: audio.codecName,
                streamIndex: audio.index,
                capabilities: capabilities
            )
            try require("aac", in: capabilities.encoders, category: .encoder)
            try require(
                "aresample",
                in: capabilities.filters,
                category: .filter
            )
        }
    }

    private func preferredVideo(
        _ streams: [VideoStreamInfo]
    ) -> VideoStreamInfo? {
        streams.filter(\.disposition.isDefault).min {
            $0.index < $1.index
        } ?? streams.min { $0.index < $1.index }
    }

    private func requireDecoder(
        codecName: String?,
        streamIndex: Int,
        capabilities: FFmpegCapabilities
    ) throws {
        guard let codecName, !codecName.isEmpty else {
            throw FFmpegPreflightError.missingCodecName(
                streamIndex: streamIndex
            )
        }
        let normalized = codecName.lowercased()
        guard capabilities.decoders.contains(normalized) else {
            throw FFmpegPreflightError.unsupportedDecoder(
                streamIndex: streamIndex,
                codecName: normalized
            )
        }
    }

    private func require(
        _ name: String,
        in capabilities: Set<String>,
        category: FFmpegCapabilityCategory
    ) throws {
        guard capabilities.contains(name) else {
            throw FFmpegPreflightError.unavailableCapability(
                category: category,
                name: name
            )
        }
    }
}
