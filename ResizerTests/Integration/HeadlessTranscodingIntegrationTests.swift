import Foundation
import Testing
@testable import Resizer

private final class HeadlessIntegrationBundleToken: NSObject {}

@Suite("Bundled headless transcode integration", .serialized)
struct HeadlessTranscodingIntegrationTests {
    @Test("Bundled probe → transcode → probe commits a validated MP4")
    func bundledProbeTranscodeProbe() async throws {
        let fixtureURL = try #require(Self.fixtureURL)
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

        let runner = ProcessRunner()
        let fileAccess = SecurityScopedFileAccess(
            startAccessing: { _ in false },
            stopAccessing: { _ in }
        )
        let prober = try FFprobeClient.bundled(processRunner: runner)
        let transcoder = try FFmpegTranscodingService.bundled(
            processRunner: runner,
            fileAccess: fileAccess
        )
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

    private static var fixtureURL: URL? {
        let bundle = Bundle(for: HeadlessIntegrationBundleToken.self)
        return bundle.url(
            forResource: "short-h264-aac",
            withExtension: "mp4",
            subdirectory: "Fixtures/Media"
        ) ?? bundle.url(
            forResource: "short-h264-aac",
            withExtension: "mp4"
        )
    }
}
