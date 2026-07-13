import Foundation
import Testing
@testable import Resizer

@Suite("Application service contracts")
struct ServiceContractTests {
    @Test("Output plan keeps input, temporary, and final URLs distinct")
    func outputPlanValidation() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/source.mov")
        let outputDirectory = URL(
            fileURLWithPath: "/tmp/ResizerOutput",
            isDirectory: true
        )
        let jobID = UUID()
        let request = OutputPlanningRequest(
            jobID: jobID,
            inputURL: inputURL,
            policy: try OutputPolicy(directoryURL: outputDirectory)
        )
        let temporaryURL = outputDirectory.appendingPathComponent(
            "\(jobID.uuidString).partial.mp4"
        )
        let finalURL = outputDirectory.appendingPathComponent("output.mp4")
        let plan = try OutputPlan(
            request: request,
            temporaryURL: temporaryURL,
            finalURL: finalURL
        )

        #expect(plan.inputURL == inputURL)
        #expect(plan.temporaryURL == temporaryURL)
        #expect(plan.finalURL == finalURL)
        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: request,
                temporaryURL: inputURL,
                finalURL: finalURL
            )
        }
        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: request,
                temporaryURL: temporaryURL,
                finalURL: temporaryURL
            )
        }
        #expect(throws: OutputPlanValidationError.invalidPlan) {
            _ = try OutputPlan(
                request: request,
                temporaryURL: outputDirectory.appendingPathComponent(
                    "someone-else.partial.mp4"
                ),
                finalURL: finalURL
            )
        }
    }

    @Test("Transcode and command requests derive from a validated output plan")
    func transcodeRequestProvenance() throws {
        let jobID = UUID()
        let directory = URL(
            fileURLWithPath: "/tmp/ResizerOutput",
            isDirectory: true
        )
        let planningRequest = OutputPlanningRequest(
            jobID: jobID,
            inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
            policy: try OutputPolicy(directoryURL: directory)
        )
        let plan = try OutputPlan(
            request: planningRequest,
            temporaryURL: directory.appendingPathComponent(
                "\(jobID.uuidString).partial.mp4"
            ),
            finalURL: directory.appendingPathComponent("output.mp4")
        )
        let configuration = try TestFixtures.configuration()
        let request = TranscodeRequest(
            outputPlan: plan,
            mediaInfo: try TestFixtures.mediaInfo(),
            recipe: configuration.recipe
        )
        let commandRequest = TranscodeCommandRequest(
            transcodeRequest: request
        )

        #expect(request.jobID == plan.jobID)
        #expect(request.inputURL == plan.inputURL)
        #expect(request.temporaryOutputURL == plan.temporaryURL)
        #expect(commandRequest.jobID == request.jobID)
        #expect(commandRequest.inputURL == request.inputURL)
        #expect(commandRequest.temporaryOutputURL == request.temporaryOutputURL)
        #expect(try TranscodeResult(byteCount: 1).byteCount == 1)
        #expect(throws: TranscodeContractValidationError.invalidResult) {
            _ = try TranscodeResult(byteCount: 0)
        }
    }

    @Test("Process diagnostics cannot exceed their declared bound")
    func boundedDiagnostics() throws {
        let diagnostic = try BoundedData(
            data: Data([1, 2, 3]),
            byteLimit: 3,
            wasTruncated: true
        )

        #expect(diagnostic.data.count == diagnostic.byteLimit)
        #expect(diagnostic.wasTruncated)
        #expect(throws: ProcessContractValidationError.invalidBoundedData) {
            _ = try BoundedData(
                data: Data([1, 2, 3]),
                byteLimit: 2,
                wasTruncated: true
            )
        }
        #expect(throws: ProcessContractValidationError.invalidRequest) {
            _ = try ProcessRequest(
                executableURL: URL(string: "https://example.com/tool")!,
                arguments: [],
                environment: [:],
                diagnosticByteLimit: 1
            )
        }
    }
}
