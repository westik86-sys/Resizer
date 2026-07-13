import Foundation
import Testing
@testable import Resizer

@Suite("Safe output planner")
struct OutputPlannerTests {
    @Test("No conflict creates the base final and job-owned temporary names")
    func noConflict() async throws {
        let request = try makeRequest()
        let planner = OutputPlanner(fileExists: { _ in false })

        let plan = try await planner.planOutput(for: request)

        #expect(
            plan.finalURL.path
                == "/output/source-compressed.mp4"
        )
        #expect(
            plan.temporaryURL.path
                == "/output/source-compressed.\(jobToken).partial.mp4"
        )
        #expect(plan.inputURL == request.inputURL)
        #expect(plan.jobID == request.jobID)
    }

    @Test("The first existing final name receives numeric suffix -2")
    func firstNumericSuffix() async throws {
        let existing = Set(["/output/source-compressed.mp4"])
        let planner = planner(existingPaths: existing)

        let plan = try await planner.planOutput(for: makeRequest())

        #expect(plan.finalURL.path == "/output/source-compressed-2.mp4")
        #expect(
            plan.temporaryURL.path
                == "/output/source-compressed-2.\(jobToken).partial.mp4"
        )
    }

    @Test("Sequential conflicts advance the numeric suffix to -3")
    func nextNumericSuffix() async throws {
        let existing = Set([
            "/output/source-compressed.mp4",
            "/output/source-compressed-2.mp4",
        ])
        let planner = planner(existingPaths: existing)

        let plan = try await planner.planOutput(for: makeRequest())

        #expect(plan.finalURL.path == "/output/source-compressed-3.mp4")
        #expect(
            plan.temporaryURL.path
                == "/output/source-compressed-3.\(jobToken).partial.mp4"
        )
    }

    @Test("Fail conflict policy returns a typed collision")
    func failConflictPolicy() async throws {
        let planner = planner(
            existingPaths: ["/output/source-compressed.mp4"]
        )
        let request = try makeRequest(conflictPolicy: .fail)

        await expectError(.outputCollision) {
            try await planner.planOutput(for: request)
        }
    }

    @Test("An existing job-owned temporary path returns a typed collision")
    func temporaryCollision() async throws {
        let temporaryPath =
            "/output/source-compressed.\(jobToken).partial.mp4"
        let planner = planner(existingPaths: [temporaryPath])

        await expectError(.temporaryCollision) {
            try await planner.planOutput(for: self.makeRequest())
        }
    }

    @Test("An MP4 input in the output directory is never selected as output")
    func inputMP4IsNeverOverwritten() async throws {
        let inputURL = URL(fileURLWithPath: "/output/source.mp4")
        let planner = planner(existingPaths: [inputURL.path])
        let request = try makeRequest(inputURL: inputURL)

        let plan = try await planner.planOutput(for: request)

        #expect(plan.inputURL.standardizedFileURL == inputURL.standardizedFileURL)
        #expect(plan.finalURL.standardizedFileURL != inputURL.standardizedFileURL)
        #expect(
            plan.temporaryURL.standardizedFileURL
                != inputURL.standardizedFileURL
        )
        #expect(plan.finalURL.path == "/output/source-compressed.mp4")
    }

    @Test("Unicode and shell metacharacters remain literal path characters")
    func literalUnicodeAndShellCharacters() async throws {
        let sourceName = "Видео 🧪 $HOME;$(touch nope) [one]"
        let inputURL = URL(
            fileURLWithPath: "/input/\(sourceName).mov"
        )
        let outputDirectory = URL(
            fileURLWithPath: "/output/Папка с пробелами",
            isDirectory: true
        )
        let request = try makeRequest(
            inputURL: inputURL,
            outputDirectoryURL: outputDirectory
        )
        let planner = OutputPlanner(fileExists: { _ in false })

        let plan = try await planner.planOutput(for: request)

        #expect(
            plan.finalURL.lastPathComponent
                == "\(sourceName)-compressed.mp4"
        )
        #expect(
            plan.temporaryURL.lastPathComponent
                == "\(sourceName)-compressed.\(jobToken).partial.mp4"
        )
        #expect(
            plan.finalURL.deletingLastPathComponent().standardizedFileURL
                == outputDirectory.standardizedFileURL
        )
    }

    @Test("Remote or relative file URLs are rejected before name planning")
    func invalidLocalURLs() async throws {
        let planner = OutputPlanner(fileExists: { _ in false })
        let remoteInputRequest = try makeRequest(
            inputURL: try #require(URL(string: "https://example.com/source.mov"))
        )

        await expectError(.invalidInputURL) {
            try await planner.planOutput(for: remoteInputRequest)
        }

        let relativeDirectory = try #require(URL(string: "file:relative"))
        let relativeOutputRequest = OutputPlanningRequest(
            jobID: jobID,
            inputURL: URL(fileURLWithPath: "/input/source.mov"),
            policy: try OutputPolicy(directoryURL: relativeDirectory)
        )
        await expectError(.invalidOutputDirectoryURL) {
            try await planner.planOutput(for: relativeOutputRequest)
        }
    }

    private let jobID = UUID(
        uuidString: "12345678-9ABC-4DEF-8123-456789ABCDEF"
    )!

    private var jobToken: String {
        jobID.uuidString.lowercased()
    }

    private func makeRequest(
        inputURL: URL = URL(fileURLWithPath: "/input/source.mov"),
        outputDirectoryURL: URL = URL(
            fileURLWithPath: "/output",
            isDirectory: true
        ),
        conflictPolicy: OutputConflictPolicy = .appendNumericSuffix
    ) throws -> OutputPlanningRequest {
        OutputPlanningRequest(
            jobID: jobID,
            inputURL: inputURL,
            policy: try OutputPolicy(
                directoryURL: outputDirectoryURL,
                conflictPolicy: conflictPolicy
            )
        )
    }

    private func planner(existingPaths: Set<String>) -> OutputPlanner {
        OutputPlanner { url in
            existingPaths.contains(url.standardizedFileURL.path)
        }
    }

    private func expectError(
        _ expectedError: OutputPlannerError,
        operation: () async throws -> OutputPlan
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected OutputPlannerError.\(expectedError)")
        } catch let error as OutputPlannerError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
