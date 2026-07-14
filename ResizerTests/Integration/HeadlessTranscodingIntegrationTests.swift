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

    @Test("Bundled H.264 probe → transcode → probe commits a validated MP4")
    func bundledProbeTranscodeProbe() async throws {
        try await runWorkflow(
            fixtureName: "short-h264-aac",
            expectedInputVideoCodec: "h264"
        )
    }

    @Test("Bundled HEVC input becomes a validated H.264/AAC MP4")
    func bundledHEVCProbeTranscodeProbe() async throws {
        try await runWorkflow(
            fixtureName: "short-hevc-aac",
            expectedInputVideoCodec: "hevc"
        )
    }

    @Test("Two bundled jobs complete through one production queue")
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
        let configuration = JobConfiguration(
            recipe: try CompressionRecipe(preset: .balanced),
            outputPolicy: try OutputPolicy(directoryURL: outputDirectory)
        )
        for jobID in jobIDs {
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
                       $0 == .completed || $0 == .failed || $0 == .cancelled
                   }) {
                    return snapshot
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        #expect(terminalSnapshot.jobs.map(\.id) == jobIDs)
        for job in terminalSnapshot.jobs {
            guard case .completed(let result) = job.state else {
                Issue.record("Expected completed queue job, got \(job.state)")
                continue
            }
            #expect(result.outputByteCount > 0)
            #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
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
        expectedInputVideoCodec: String
    ) async throws {
        let fixtureURL = try #require(Self.fixtureURL(named: fixtureName))
        let originalFixtureData = try Data(contentsOf: fixtureURL)
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
        let job = try await coordinator.createJob(inputURL: fixtureURL)
        let configuration = JobConfiguration(
            recipe: try CompressionRecipe(preset: .balanced),
            outputPolicy: try OutputPolicy(
                directoryURL: outputDirectory
            )
        )

        let completed = try await ProcessHarnessFixture.withTimeout(
            after: .seconds(60)
        ) {
            try await coordinator.process(
                jobID: job.id,
                configuration: configuration
            )
        }

        guard case .completed(let result) = completed.state else {
            Issue.record("Expected completed workflow, got \(completed.state)")
            return
        }
        #expect(
            completed.mediaInfo?.videoStreams.first?.codecName
                == expectedInputVideoCodec
        )
        #expect(result.outputURL.standardizedFileURL != fixtureURL.standardizedFileURL)
        #expect(result.outputByteCount > 0)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))

        let outputMedia = try await prober.probe(result.outputURL)
        try TranscodeOutputValidator().validate(
            output: outputMedia,
            source: try #require(completed.mediaInfo),
            recipe: configuration.recipe
        )
        #expect(outputMedia.formatNames.contains("mp4"))
        #expect(outputMedia.videoStreams.first?.codecName == "h264")
        #expect(outputMedia.audioStreams.count == 1)
        #expect(outputMedia.audioStreams.first?.codecName == "aac")
        #expect(try Data(contentsOf: fixtureURL) == originalFixtureData)
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
