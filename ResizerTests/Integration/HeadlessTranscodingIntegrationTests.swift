import Foundation
import Testing
@testable import Resizer

private final class HeadlessIntegrationBundleToken: NSObject {}

private struct HeadlessIntegrationDependencies: Sendable {
    let runner: ProcessRunner
    let fileAccess: SecurityScopedFileAccess
    let prober: FFprobeClient
    let transcoder: FFmpegTranscodingService
}

/// Mirrors the app composition root: one long-lived process runner and
/// transcoder serve the sequential queue, so bundled capability discovery is
/// cached once instead of being repeated between fixture cases.
private actor HeadlessIntegrationEnvironment {
    private let runner = ProcessRunner()
    private let fileAccess = SecurityScopedFileAccess(
        startAccessing: { _ in false },
        stopAccessing: { _ in }
    )
    private var cachedDependencies: HeadlessIntegrationDependencies?

    func dependencies() throws -> HeadlessIntegrationDependencies {
        if let cachedDependencies {
            return cachedDependencies
        }
        let dependencies = HeadlessIntegrationDependencies(
            runner: runner,
            fileAccess: fileAccess,
            prober: try FFprobeClient.bundled(processRunner: runner),
            transcoder: try FFmpegTranscodingService.bundled(
                processRunner: runner,
                fileAccess: fileAccess
            )
        )
        cachedDependencies = dependencies
        return dependencies
    }
}

@Suite("Bundled headless transcode integration", .serialized)
struct HeadlessTranscodingIntegrationTests {
    private static let environment = HeadlessIntegrationEnvironment()

    @Test("Bundled runtime marker admits the audited libx264 profile")
    func bundledProfileMarkerDiscovery() async throws {
        let fixtureURL = try #require(
            Self.fixtureURL(named: "short-h264-aac")
        )
        let dependencies = try await Self.environment.dependencies()
        let mediaInfo = try await dependencies.prober.probe(fixtureURL)
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: mediaInfo,
            settings: .quick(audio: .keep)
        )

        try await dependencies.transcoder.validateCapabilities(
            for: mediaInfo,
            recipe: recipe
        )
    }

    @Test("Bundled H.264 probe → transcode → probe reaches a valid result")
    func bundledProbeTranscodeProbe() async throws {
        try await runWorkflow(
            fixtureName: "short-h264-aac",
            expectedInputVideoCodec: "h264"
        )
    }

    @Test("Bundled HEVC input reaches a valid automatic result")
    func bundledHEVCProbeTranscodeProbe() async throws {
        try await runWorkflow(
            fixtureName: "short-hevc-aac",
            expectedInputVideoCodec: "hevc"
        )
    }

    @Test("Bundled ten-bit SDR reaches a valid ten-bit H.264 result")
    func bundledTenBitProbeTranscodeProbe() async throws {
        try await runWorkflow(
            fixtureName: "short-hevc-main10-aac",
            expectedInputVideoCodec: "hevc"
        )
    }

    @Test("Bundled 10-bit 4:2:2 H.264 stays 10-bit 4:2:2 through Quick")
    func bundledTenBit422ProbeTranscodeProbe() async throws {
        try await runTenBitChromaWorkflow(
            outputPixelFormat: .yuv422p10le
        )
    }

    @Test("Bundled 10-bit 4:4:4 H.264 stays 10-bit 4:4:4 through Quick")
    func bundledTenBit444ProbeTranscodeProbe() async throws {
        try await runTenBitChromaWorkflow(
            outputPixelFormat: .yuv444p10le
        )
    }

    private func runTenBitChromaWorkflow(
        outputPixelFormat: OutputPixelFormat
    ) async throws {
        try #require(outputPixelFormat.bitDepth == 10)
        let fixtureURL = try #require(
            Self.fixtureURL(named: "short-h264-aac")
        )
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResizerTenBitChromaIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let tenBitURL = fixtureDirectory.appendingPathComponent(
            "short-h264-\(outputPixelFormat.rawValue).mp4"
        )
        let dependencies = try await Self.environment.dependencies()
        try await Self.createTenBitFixture(
            from: fixtureURL,
            at: tenBitURL,
            pixelFormat: outputPixelFormat,
            runner: dependencies.runner
        )

        let sourceMedia = try await dependencies.prober.probe(tenBitURL)
        let recipe = try AutomaticCompressionPolicy().recipe(
            for: sourceMedia,
            settings: .quick(audio: .keep)
        )
        #expect(sourceMedia.videoStreams.first?.codecName == "h264")
        #expect(
            sourceMedia.videoStreams.first?.pixelFormat
                == outputPixelFormat.rawValue
        )
        #expect(sourceMedia.videoStreams.first?.bitDepth == 10)
        #expect(sourceMedia.videoStreams.first?.dynamicRange == .sdr)
        #expect(
            sourceMedia.videoStreams.first?.colorMetadata.transfer
                == "bt709"
        )
        #expect(
            sourceMedia.videoStreams.first?.sampleAspectRatio?.isSquare
                != false
        )
        #expect(recipe.videoCodec == .h264Libx264)
        #expect(recipe.outputPixelFormat == outputPixelFormat)
        #expect(
            recipe.rateControl
                == .libx264CRF(try X264ConstantRateFactor(22))
        )

        let preflightPlan = try await OutputPlanner().planOutput(
            for: OutputPlanningRequest(
                jobID: UUID(),
                inputURL: tenBitURL,
                policy: try OutputPolicy(directoryURL: fixtureDirectory)
            )
        )
        try await dependencies.transcoder.preflight(
            TranscodeRequest(
                outputPlan: preflightPlan,
                mediaInfo: sourceMedia,
                recipe: recipe
            )
        )

        try await runWorkflow(
            inputURL: tenBitURL,
            expectedInputVideoCodec: "h264",
            requiresPublishedOutput: true
        )
    }

    @Test("Bundled MP4 output suppresses a source timecode data track")
    func bundledTimecodeInputDoesNotRecreateTMCD() async throws {
        let fixtureURL = try #require(
            Self.fixtureURL(named: "short-h264-aac")
        )
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResizerTimecodeIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }

        let timecodeInputURL = fixtureDirectory.appendingPathComponent(
            "short-h264-aac-timecode.mp4"
        )
        let dependencies = try await Self.environment.dependencies()
        try await Self.createTimecodeFixture(
            from: fixtureURL,
            at: timecodeInputURL,
            runner: dependencies.runner
        )
        let sourceMedia = try await dependencies.prober.probe(
            timecodeInputURL
        )
        #expect(
            sourceMedia.streams.contains { stream in
                guard case .other(let other) = stream else { return false }
                return other.codecType == "data"
            }
        )

        try await runWorkflow(
            inputURL: timecodeInputURL,
            expectedInputVideoCodec: "h264"
        )
    }

    @Test("Two bundled jobs reach terminal results through one production queue")
    func bundledSequentialQueue() async throws {
        let fixtureURLs = try ["short-h264-aac", "short-hevc-aac"].map {
            try #require(Self.fixtureURL(named: $0))
        }
        let originalFixtureData = try fixtureURLs.map { url in
            try Data(contentsOf: url)
        }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResizerSequentialIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let dependencies = try await Self.environment.dependencies()
        let coordinator = CompressionCoordinator(
            dependencies: CompressionCoordinatorDependencies(
                mediaProber: dependencies.prober,
                transcoder: dependencies.transcoder,
                outputPlanner: OutputPlanner(),
                fileAccess: dependencies.fileAccess
            )
        )
        let jobIDs = try await coordinator.add(
            fixtureURLs.map { JobQueueImport(inputURL: $0) }
        )
        let preparedSnapshot = await coordinator.snapshot()
        for jobID in jobIDs {
            let job = try #require(
                preparedSnapshot.jobs.first { $0.id == jobID }
            )
            let mediaInfo = try #require(job.mediaInfo)
            let configuration = JobConfiguration(
                recipe: try AutomaticCompressionPolicy().recipe(
                    for: mediaInfo,
                    settings: .quick(audio: .keep)
                ),
                outputPolicy: try OutputPolicy(
                    directoryURL: outputDirectory
                )
            )
            _ = try await coordinator.enqueue(
                jobID: jobID,
                configuration: configuration
            )
        }

        await coordinator.startQueue()
        let terminalSnapshot = try await ProcessHarnessFixture.withTimeout(
            after: .seconds(60)
        ) {
            while true {
                let snapshot = await coordinator.snapshot()
                let phases = snapshot.jobs.map(\.state.phase)
                if !snapshot.isDraining,
                   phases.count == jobIDs.count,
                   phases.allSatisfy({
                       $0 == .completed
                           || $0 == .noBenefit
                           || $0 == .failed
                           || $0 == .cancelled
                   }) {
                    return snapshot
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        #expect(terminalSnapshot.jobs.map(\.id) == jobIDs)
        for job in terminalSnapshot.jobs {
            switch job.state {
            case .completed(let result):
                #expect(result.outputByteCount > 0)
                #expect(result.outputByteCount < result.sourceByteCount)
                #expect(
                    FileManager.default.fileExists(
                        atPath: result.outputURL.path
                    )
                )
            case .noBenefit(let result):
                #expect(result.candidateByteCount >= result.sourceByteCount)
            default:
                Issue.record(
                    "Expected completed or no-benefit queue job, got \(job.state)"
                )
            }
        }
        #expect(await dependencies.runner.activeExecutionCount() == 0)
        #expect(
            try fixtureURLs.map { url in
                try Data(contentsOf: url)
            } == originalFixtureData
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            ).allSatisfy {
                !$0.lastPathComponent.hasSuffix(".partial.mp4")
            }
        )
    }

    private func runWorkflow(
        fixtureName: String,
        expectedInputVideoCodec: String,
        requiresPublishedOutput: Bool = false
    ) async throws {
        let fixtureURL = try #require(Self.fixtureURL(named: fixtureName))
        try await runWorkflow(
            inputURL: fixtureURL,
            expectedInputVideoCodec: expectedInputVideoCodec,
            requiresPublishedOutput: requiresPublishedOutput
        )
    }

    private func runWorkflow(
        inputURL: URL,
        expectedInputVideoCodec: String,
        requiresPublishedOutput: Bool = false
    ) async throws {
        let originalFixtureData = try Data(contentsOf: inputURL)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResizerHeadlessIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let dependencies = try await Self.environment.dependencies()
        let runner = dependencies.runner
        let fileAccess = dependencies.fileAccess
        let prober = dependencies.prober
        let transcoder = dependencies.transcoder
        let coordinator = CompressionCoordinator(
            dependencies: CompressionCoordinatorDependencies(
                mediaProber: prober,
                transcoder: transcoder,
                outputPlanner: OutputPlanner(),
                fileAccess: fileAccess
            )
        )
        let job = try await coordinator.createJob(inputURL: inputURL)
        let sourceMedia = try await prober.probe(inputURL)
        let configuration = JobConfiguration(
            recipe: try AutomaticCompressionPolicy().recipe(
                for: sourceMedia,
                settings: .quick(audio: .keep)
            ),
            outputPolicy: try OutputPolicy(
                directoryURL: outputDirectory
            )
        )
        #expect(sourceMedia.preferredAudioStream?.channelCount == 1)
        #expect(
            configuration.recipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 69_000)
            )
        )

        let terminal = try await ProcessHarnessFixture.withTimeout(
            after: .seconds(60)
        ) {
            try await coordinator.process(
                jobID: job.id,
                configuration: configuration
            )
        }

        #expect(
            terminal.mediaInfo?.videoStreams.first?.codecName
                == expectedInputVideoCodec
        )
        switch terminal.state {
        case .completed(let result):
            #expect(
                result.outputURL.standardizedFileURL
                    != inputURL.standardizedFileURL
            )
            #expect(result.outputByteCount > 0)
            #expect(result.outputByteCount < result.sourceByteCount)
            #expect(
                FileManager.default.fileExists(atPath: result.outputURL.path)
            )

            let outputMedia = try await prober.probe(result.outputURL)
            try TranscodeOutputValidator().validate(
                output: outputMedia,
                source: try #require(terminal.mediaInfo),
                recipe: configuration.recipe
            )
            #expect(outputMedia.formatNames.contains("mp4"))
            #expect(outputMedia.videoStreams.first?.codecName == "h264")
            #expect(
                outputMedia.videoStreams.first?.pixelFormat
                    == configuration.recipe.outputPixelFormat.rawValue
            )
            #expect(
                outputMedia.videoStreams.first?.bitDepth
                    == configuration.recipe.outputPixelFormat.bitDepth
            )
            #expect(outputMedia.audioStreams.count == 1)
            #expect(outputMedia.audioStreams.first?.codecName == "aac")
            #expect(
                outputMedia.streams.allSatisfy { stream in
                    switch stream {
                    case .video, .audio:
                        true
                    case .subtitle, .other:
                        false
                    }
                }
            )
        case .noBenefit(let result):
            #expect(result.candidateByteCount >= result.sourceByteCount)
            if requiresPublishedOutput {
                Issue.record(
                    "Expected the lossless fixture to produce a smaller copy"
                )
            }
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: outputDirectory,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        default:
            Issue.record(
                "Expected completed or no-benefit workflow, got \(terminal.state)"
            )
        }
        #expect(try Data(contentsOf: inputURL) == originalFixtureData)
        #expect(await runner.activeExecutionCount() == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: nil
            ).allSatisfy {
                !$0.lastPathComponent.hasSuffix(".partial.mp4")
            }
        )
    }

    /// Creates a disposable input fixture through the bundled executable.
    /// This deliberately enables MP4 tmcd generation so the production
    /// command must suppress it again while preserving common metadata.
    private static func createTimecodeFixture(
        from sourceURL: URL,
        at outputURL: URL,
        runner: ProcessRunner
    ) async throws {
        let executableURL = try #require(
            Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")
        )
        let request = try ProcessRequest(
            executableURL: executableURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-i", sourceURL.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c", "copy",
                "-metadata:s:v:0", "timecode=00:00:00:00",
                "-write_tmcd", "1",
                "-movflags", "+faststart",
                "-f", "mp4",
                "-y", outputURL.path,
            ],
            environment: [:],
            diagnosticByteLimit: 64 * 1_024
        )
        let collected = try await ProcessHarnessFixture.collect(
            try await runner.start(request)
        )
        try #require(collected.result.termination.status == 0)
        try #require(
            FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    /// Builds the motivating source shape with the same bundled binary used
    /// by production. Lossless x264 makes the subsequent CRF 22 Quick encode
    /// predictably beneficial while preserving a byte-for-byte immutable
    /// input for the workflow assertion.
    private static func createTenBitFixture(
        from sourceURL: URL,
        at outputURL: URL,
        pixelFormat: OutputPixelFormat,
        runner: ProcessRunner
    ) async throws {
        try #require(pixelFormat.bitDepth == 10)
        let executableURL = try #require(
            Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")
        )
        let request = try ProcessRequest(
            executableURL: executableURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-i", sourceURL.path,
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "libx264",
                "-crf", "0",
                "-preset", "medium",
                "-pix_fmt", pixelFormat.rawValue,
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-color_range", "tv",
                "-x264-params",
                "colorprim=bt709:transfer=bt709:colormatrix=bt709",
                "-c:a", "copy",
                "-movflags", "+faststart",
                "-f", "mp4",
                "-y", outputURL.path,
            ],
            environment: [:],
            diagnosticByteLimit: 64 * 1_024
        )
        let collected = try await ProcessHarnessFixture.collect(
            try await runner.start(request)
        )
        try #require(collected.result.termination.status == 0)
        try #require(
            FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: HeadlessIntegrationBundleToken.self)
        return bundle.url(
            forResource: name,
            withExtension: "mp4",
            subdirectory: "Fixtures/Media"
        ) ?? bundle.url(
            forResource: name,
            withExtension: "mp4"
        )
    }
}
