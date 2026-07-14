import Foundation
import Testing
@testable import Resizer

@Suite("Security-scoped local file access")
struct SecurityScopedFileAccessTests {
    @Test("Selected URLs are deduplicated and held for the async operation")
    func securityScopeLifetimeAndDeduplication() async throws {
        let first = URL(fileURLWithPath: "/tmp/Resizer Scope/input.mov")
        let duplicate = URL(
            fileURLWithPath: "/tmp/Resizer Scope/folder/../input.mov"
        )
        let second = URL(fileURLWithPath: "/tmp/Resizer Scope/output")
        let recorder = SecurityScopeRecorder()
        let access = SecurityScopedFileAccess(
            startAccessing: recorder.start,
            stopAccessing: recorder.stop
        )

        let value = try await access.withSecurityScopedAccess(
            to: [first, duplicate, second, first]
        ) {
            #expect(
                recorder.activePaths
                    == Set([first.path, second.path])
            )
            await Task.yield()
            #expect(
                recorder.activePaths
                    == Set([first.path, second.path])
            )
            return 42
        }

        #expect(value == 42)
        #expect(recorder.startedPaths == [first.path, second.path])
        #expect(recorder.stoppedPaths == [second.path, first.path])
        #expect(recorder.activePaths.isEmpty)
    }

    @Test("Security scopes are released when an async operation throws")
    func securityScopeReleasedOnFailure() async {
        let inputURL = URL(fileURLWithPath: "/tmp/input.mov")
        let outputURL = URL(fileURLWithPath: "/tmp/output")
        let recorder = SecurityScopeRecorder()
        let access = SecurityScopedFileAccess(
            startAccessing: recorder.start,
            stopAccessing: recorder.stop
        )

        do {
            let _: Int = try await access.withSecurityScopedAccess(
                to: [inputURL, outputURL]
            ) {
                #expect(recorder.activePaths.count == 2)
                throw ExpectedFailure.operation
            }
            Issue.record("Expected the operation to fail")
        } catch ExpectedFailure.operation {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(recorder.stoppedPaths == [outputURL.path, inputURL.path])
        #expect(recorder.activePaths.isEmpty)
    }

    @Test("A scope that was not started is not stopped")
    func unsuccessfulScopeStartIsNotStopped() async throws {
        let inputURL = URL(fileURLWithPath: "/tmp/input.mov")
        let outputURL = URL(fileURLWithPath: "/tmp/output")
        let recorder = SecurityScopeRecorder(
            pathsThatStart: [inputURL.path]
        )
        let access = SecurityScopedFileAccess(
            startAccessing: recorder.start,
            stopAccessing: recorder.stop
        )

        try await access.withSecurityScopedAccess(
            to: [inputURL, outputURL]
        ) {
            #expect(recorder.activePaths == Set([inputURL.path]))
        }

        #expect(recorder.startedPaths == [inputURL.path, outputURL.path])
        #expect(recorder.stoppedPaths == [inputURL.path])
    }

    @Test("Invalid selected URLs fail before any scope is started")
    func invalidSelectedURL() async {
        let recorder = SecurityScopeRecorder()
        let access = SecurityScopedFileAccess(
            startAccessing: recorder.start,
            stopAccessing: recorder.stop
        )
        let remoteURL = URL(string: "https://example.com/video.mov")!

        await expectError(.invalidURL) {
            try await access.withSecurityScopedAccess(to: [remoteURL]) {}
        }

        #expect(recorder.startedPaths.isEmpty)
        #expect(recorder.stoppedPaths.isEmpty)
    }

    @Test("Metadata distinguishes files, directories, missing paths, and links")
    func metadata() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let fileURL = directory.url.appendingPathComponent("video.mov")
        let folderURL = directory.url.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        let linkURL = directory.url.appendingPathComponent("video-link.mov")
        let bytes = Data([0, 1, 2, 3, 4])
        try bytes.write(to: fileURL)
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: fileURL
        )
        let access = SecurityScopedFileAccess()

        let fileMetadata = try #require(await access.metadata(at: fileURL))
        let directoryMetadata = try #require(
            await access.metadata(at: folderURL)
        )
        let missingMetadata = try await access.metadata(
            at: directory.url.appendingPathComponent("missing.mov")
        )

        #expect(fileMetadata.byteCount == Int64(bytes.count))
        #expect(!fileMetadata.isDirectory)
        #expect(fileMetadata.identity != nil)
        #expect(fileMetadata.modificationTimeNanoseconds != nil)
        #expect(fileMetadata.statusChangeTimeNanoseconds != nil)
        #expect(directoryMetadata.isDirectory)
        #expect(missingMetadata == nil)
        await expectError(.symbolicLinkNotAllowed) {
            try await access.metadata(at: linkURL)
        }
    }

    @Test("Reservation atomically creates one empty identity-sealed file")
    func reserveTemporaryOutput() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess()

        let reservation = try await access.reserveTemporaryOutput(
            fixture.plan
        )

        #expect(reservation.jobID == fixture.plan.jobID)
        #expect(reservation.temporaryURL == fixture.plan.temporaryURL)
        #expect(reservation.metadata.byteCount == 0)
        #expect(reservation.metadata.identity != nil)
        #expect(
            try Data(contentsOf: fixture.plan.temporaryURL).isEmpty
        )
        await expectError(.temporaryOutputAlreadyExists) {
            try await access.reserveTemporaryOutput(fixture.plan)
        }
    }

    @Test("Commit atomically publishes the temporary file without changing input")
    func commitPublishesTemporaryFile() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        let outputData = Data("encoded output".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        try outputData.write(to: fixture.plan.temporaryURL)

        try await SecurityScopedFileAccess().commitWithoutReplacing(
            fixture.plan
        )

        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
        #expect(try Data(contentsOf: fixture.plan.finalURL) == outputData)
        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
    }

    @Test("Commit never replaces an existing final output")
    func commitRejectsExistingFinalOutput() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        let temporaryData = Data("new output".utf8)
        let existingData = Data("existing output".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        try temporaryData.write(to: fixture.plan.temporaryURL)
        try existingData.write(to: fixture.plan.finalURL)
        let access = SecurityScopedFileAccess()

        await expectError(.finalOutputAlreadyExists) {
            try await access.commitWithoutReplacing(fixture.plan)
        }

        #expect(try Data(contentsOf: fixture.plan.finalURL) == existingData)
        #expect(try Data(contentsOf: fixture.plan.temporaryURL) == temporaryData)
        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
    }

    @Test("Commit rejects a temporary replaced after validation")
    func commitRejectsChangedTemporaryIdentity() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        try Data("validated".utf8).write(to: fixture.plan.temporaryURL)
        let access = SecurityScopedFileAccess()
        let validatedMetadata = try #require(
            await access.metadata(at: fixture.plan.temporaryURL)
        )

        try FileManager.default.removeItem(at: fixture.plan.temporaryURL)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: fixture.plan.temporaryURL)

        await expectError(.temporaryOutputChanged) {
            try await access.commitWithoutReplacing(
                fixture.plan,
                expectedTemporaryMetadata: validatedMetadata
            )
        }

        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
        #expect(try Data(contentsOf: fixture.plan.temporaryURL) == replacement)
    }

    @Test("Cleanup is idempotent and removes only the exact job temporary path")
    func cleanupIsExactAndIdempotent() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let neighboringURL = fixture.outputDirectoryURL.appendingPathComponent(
            "neighbor.partial.mp4"
        )
        let finalData = Data("existing final".utf8)
        let neighboringData = Data("neighbor".utf8)
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        try Data("temporary".utf8).write(to: fixture.plan.temporaryURL)
        try finalData.write(to: fixture.plan.finalURL)
        try neighboringData.write(to: neighboringURL)
        let access = SecurityScopedFileAccess()
        let ownedMetadata = try #require(
            await access.metadata(at: fixture.plan.temporaryURL)
        )

        try await access.cleanupTemporaryOutput(
            fixture.plan,
            expectedTemporaryMetadata: ownedMetadata
        )
        try await access.cleanupTemporaryOutput(
            fixture.plan,
            expectedTemporaryMetadata: ownedMetadata
        )

        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
        #expect(try Data(contentsOf: neighboringURL) == neighboringData)
        #expect(try Data(contentsOf: fixture.plan.finalURL) == finalData)
        #expect(
            FileManager.default.fileExists(atPath: fixture.plan.inputURL.path)
        )
    }

    @Test("Cleanup never unlinks an existing file without an identity seal")
    func cleanupRejectsMissingSeal() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let unrelated = Data("unrelated".utf8)
        try unrelated.write(to: fixture.plan.temporaryURL)
        let access = SecurityScopedFileAccess()

        await expectError(.temporaryOutputChanged) {
            try await access.cleanupTemporaryOutput(fixture.plan)
        }

        #expect(
            try Data(contentsOf: fixture.plan.temporaryURL) == unrelated
        )
    }

    @Test("Cleanup preserves a replacement whose metadata no longer matches")
    func cleanupRejectsReplacedTemporaryOutput() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        try Data("workflow-owned".utf8).write(
            to: fixture.plan.temporaryURL
        )
        let access = SecurityScopedFileAccess()
        let producedMetadata = try #require(
            try await access.metadata(at: fixture.plan.temporaryURL)
        )

        try FileManager.default.removeItem(at: fixture.plan.temporaryURL)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: fixture.plan.temporaryURL)

        await expectError(.temporaryOutputChanged) {
            try await access.cleanupTemporaryOutput(
                fixture.plan,
                expectedTemporaryMetadata: producedMetadata
            )
        }

        #expect(try Data(contentsOf: fixture.plan.temporaryURL) == replacement)
    }

    @Test("Cleanup removes the same owned inode after a failed validation")
    func cleanupAcceptsMutatedOwnedTemporaryOutput() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        try Data("workflow-owned".utf8).write(
            to: fixture.plan.temporaryURL
        )
        let access = SecurityScopedFileAccess()
        let producedMetadata = try #require(
            try await access.metadata(at: fixture.plan.temporaryURL)
        )

        let handle = try FileHandle(forWritingTo: fixture.plan.temporaryURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-mutated".utf8))
        try handle.close()

        try await access.cleanupTemporaryOutput(
            fixture.plan,
            expectedTemporaryMetadata: producedMetadata
        )

        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
    }

    @Test("Cleanup refuses a symbolic-link temporary output")
    func cleanupRejectsSymbolicLink() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let targetURL = fixture.outputDirectoryURL.appendingPathComponent(
            "unrelated.mp4"
        )
        let targetData = Data("unrelated".utf8)
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        try targetData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.plan.temporaryURL,
            withDestinationURL: targetURL
        )
        let access = SecurityScopedFileAccess()

        await expectError(.symbolicLinkNotAllowed) {
            try await access.cleanupTemporaryOutput(fixture.plan)
        }

        #expect(try Data(contentsOf: targetURL) == targetData)
        #expect(FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
    }

    @Test("Cleanup refuses a hard-link alias of the immutable input")
    func cleanupRejectsInputIdentityAlias() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        try FileManager.default.linkItem(
            at: fixture.plan.inputURL,
            to: fixture.plan.temporaryURL
        )
        let access = SecurityScopedFileAccess()
        let aliasMetadata = try #require(
            await access.metadata(at: fixture.plan.temporaryURL)
        )

        await expectError(.inputOutputAlias) {
            try await access.cleanupTemporaryOutput(
                fixture.plan,
                expectedTemporaryMetadata: aliasMetadata
            )
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
    }

    @Test("Commit rejects a symbolic-link input or output directory")
    func commitRejectsSymbolicLinkIdentities() async throws {
        let inputLinkFixture = try FilePlanFixture()
        defer { inputLinkFixture.remove() }
        let actualInputURL = inputLinkFixture.rootURL.appendingPathComponent(
            "actual.mov"
        )
        try Data("original".utf8).write(to: actualInputURL)
        try FileManager.default.createSymbolicLink(
            at: inputLinkFixture.plan.inputURL,
            withDestinationURL: actualInputURL
        )
        try Data("temporary".utf8).write(
            to: inputLinkFixture.plan.temporaryURL
        )
        let access = SecurityScopedFileAccess()

        await expectError(.symbolicLinkNotAllowed) {
            try await access.commitWithoutReplacing(inputLinkFixture.plan)
        }

        let linkedDirectoryFixture = try LinkedOutputDirectoryFixture()
        defer { linkedDirectoryFixture.remove() }
        try Data("original".utf8).write(
            to: linkedDirectoryFixture.plan.inputURL
        )
        try Data("temporary".utf8).write(
            to: linkedDirectoryFixture.plan.temporaryURL
        )

        await expectError(.symbolicLinkNotAllowed) {
            try await access.commitWithoutReplacing(
                linkedDirectoryFixture.plan
            )
        }
    }

    private func expectError<Result: Sendable>(
        _ expected: SecurityScopedFileAccessError,
        operation: () async throws -> Result
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected SecurityScopedFileAccessError.\(expected)")
        } catch let error as SecurityScopedFileAccessError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private enum ExpectedFailure: Error {
    case operation
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let pathsThatStart: Set<String>?
    private var started: [String] = []
    private var stopped: [String] = []
    private var active: Set<String> = []

    init(pathsThatStart: Set<String>? = nil) {
        self.pathsThatStart = pathsThatStart
    }

    func start(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        started.append(url.path)
        let didStart = pathsThatStart?.contains(url.path) ?? true
        if didStart {
            active.insert(url.path)
        }
        return didStart
    }

    func stop(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stopped.append(url.path)
        active.remove(url.path)
    }

    var startedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var stoppedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var activePaths: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
}

private struct TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResizerFileAccessTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct FilePlanFixture {
    let root: TestDirectory
    let rootURL: URL
    let outputDirectoryURL: URL
    let plan: OutputPlan

    init() throws {
        let root = try TestDirectory()
        let rootURL = root.url
        let outputDirectoryURL = rootURL.appendingPathComponent(
            "output",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: false
            )
            let jobID = UUID()
            let request = OutputPlanningRequest(
                jobID: jobID,
                inputURL: rootURL.appendingPathComponent("source.mov"),
                policy: try OutputPolicy(directoryURL: outputDirectoryURL)
            )
            plan = try OutputPlan(
                request: request,
                temporaryURL: outputDirectoryURL.appendingPathComponent(
                    "result.\(jobID.uuidString.lowercased()).partial.mp4"
                ),
                finalURL: outputDirectoryURL.appendingPathComponent(
                    "result.mp4"
                )
            )
        } catch {
            root.remove()
            throw error
        }
        self.root = root
        self.rootURL = rootURL
        self.outputDirectoryURL = outputDirectoryURL
    }

    func remove() {
        root.remove()
    }
}

private struct LinkedOutputDirectoryFixture {
    let root: TestDirectory
    let plan: OutputPlan

    init() throws {
        let root = try TestDirectory()
        do {
            let actualOutputURL = root.url.appendingPathComponent(
                "actual-output",
                isDirectory: true
            )
            let linkedOutputURL = root.url.appendingPathComponent(
                "linked-output",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: actualOutputURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: linkedOutputURL,
                withDestinationURL: actualOutputURL
            )
            let jobID = UUID()
            let request = OutputPlanningRequest(
                jobID: jobID,
                inputURL: root.url.appendingPathComponent("source.mov"),
                policy: try OutputPolicy(directoryURL: linkedOutputURL)
            )
            plan = try OutputPlan(
                request: request,
                temporaryURL: linkedOutputURL.appendingPathComponent(
                    "result.\(jobID.uuidString.lowercased()).partial.mp4"
                ),
                finalURL: linkedOutputURL.appendingPathComponent("result.mp4")
            )
        } catch {
            root.remove()
            throw error
        }
        self.root = root
    }

    func remove() {
        root.remove()
    }
}
