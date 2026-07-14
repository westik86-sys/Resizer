import Darwin
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

    @Test("Reservation keeps an identity-sealed anonymous file descriptor")
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
        #expect(reservation.lease.fileDescriptor != nil)
        #expect(reservation.lease.directoryDescriptor != nil)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        var status = stat()
        #expect(Darwin.fstat(descriptor, &status) == 0)
        #expect(status.st_nlink == 0)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
        #expect(try await access.metadata(for: reservation) == reservation.metadata)
    }

    @Test("Descriptor commit publishes the exact anonymous file without replacement")
    func descriptorCommitPublishesReservedFile() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess()
        let reservation = try await access.reserveTemporaryOutput(fixture.plan)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        let outputData = Data("descriptor output".utf8)
        try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).write(contentsOf: outputData)
        let producedMetadata = try #require(
            await access.metadata(for: reservation)
        )

        try await access.commitWithoutReplacing(
            fixture.plan,
            reservation: reservation,
            expectedTemporaryMetadata: producedMetadata
        )

        #expect(try Data(contentsOf: fixture.plan.finalURL) == outputData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
    }

    @Test("Descriptor commit never trusts a replacement temporary pathname")
    func descriptorCommitPreservesTemporaryPathReplacement() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess()
        let reservation = try await access.reserveTemporaryOutput(fixture.plan)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        let outputData = Data("sealed descriptor output".utf8)
        try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).write(contentsOf: outputData)
        let producedMetadata = try #require(
            await access.metadata(for: reservation)
        )
        let replacementData = Data("unrelated replacement".utf8)
        try replacementData.write(to: fixture.plan.temporaryURL)

        try await access.commitWithoutReplacing(
            fixture.plan,
            reservation: reservation,
            expectedTemporaryMetadata: producedMetadata
        )

        #expect(try Data(contentsOf: fixture.plan.finalURL) == outputData)
        #expect(
            try Data(contentsOf: fixture.plan.temporaryURL) == replacementData
        )
    }

    @Test("Descriptor commit maps an fsync storage failure")
    func descriptorCommitMapsFsyncInsufficientStorage() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess(
            supportsFileCloning: { _ in true },
            synchronizeFile: { _ in
                errno = ENOSPC
                return -1
            }
        )
        let reservation = try await access.reserveTemporaryOutput(fixture.plan)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).write(contentsOf: Data("validated output".utf8))
        let producedMetadata = try #require(
            await access.metadata(for: reservation)
        )

        await expectError(.insufficientStorage) {
            try await access.commitWithoutReplacing(
                fixture.plan,
                reservation: reservation,
                expectedTemporaryMetadata: producedMetadata
            )
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
    }

    @Test("Descriptor commit maps a clone storage failure")
    func descriptorCommitMapsCloneInsufficientStorage() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess(
            supportsFileCloning: { _ in true },
            synchronizeFile: { _ in 0 },
            cloneFile: { _, _, _ in
                errno = EDQUOT
                return -1
            }
        )
        let reservation = try await access.reserveTemporaryOutput(fixture.plan)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).write(contentsOf: Data("validated output".utf8))
        let producedMetadata = try #require(
            await access.metadata(for: reservation)
        )

        await expectError(.insufficientStorage) {
            try await access.commitWithoutReplacing(
                fixture.plan,
                reservation: reservation,
                expectedTemporaryMetadata: producedMetadata
            )
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
    }

    @Test("Descriptor cleanup preserves replacements and existing final output")
    func descriptorCleanupPreservesUnrelatedPaths() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess()
        let reservation = try await access.reserveTemporaryOutput(fixture.plan)
        let descriptor = try #require(reservation.lease.fileDescriptor)
        try FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        ).write(contentsOf: Data("sealed output".utf8))
        let producedMetadata = try #require(
            await access.metadata(for: reservation)
        )
        let replacementData = Data("unrelated replacement".utf8)
        let existingFinalData = Data("existing final".utf8)
        try replacementData.write(to: fixture.plan.temporaryURL)
        try existingFinalData.write(to: fixture.plan.finalURL)

        await expectError(.finalOutputAlreadyExists) {
            try await access.commitWithoutReplacing(
                fixture.plan,
                reservation: reservation,
                expectedTemporaryMetadata: producedMetadata
            )
        }
        try await access.cleanupTemporaryOutput(
            fixture.plan,
            reservation: reservation,
            expectedTemporaryMetadata: producedMetadata
        )

        #expect(
            try Data(contentsOf: fixture.plan.temporaryURL) == replacementData
        )
        #expect(try Data(contentsOf: fixture.plan.finalURL) == existingFinalData)
    }

    @Test("Reservation rejects missing clone support before creating staging")
    func reserveRejectsUnsupportedOutputFileSystem() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        let recorder = TemporaryFileCreationRecorder()
        let access = SecurityScopedFileAccess(
            supportsFileCloning: { _ in false },
            createTemporaryFile: recorder.create
        )

        await expectError(.unsupportedOutputFileSystem) {
            try await access.reserveTemporaryOutput(fixture.plan)
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
        #expect(recorder.callCount == 0)
    }

    @Test("Reservation maps a clone capability query failure")
    func reserveMapsCloneCapabilityQueryFailure() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess(
            supportsFileCloning: { _ in throw ExpectedFailure.operation }
        )

        await expectError(.reservationFailed) {
            try await access.reserveTemporaryOutput(fixture.plan)
        }

        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
    }

    @Test(
        "Reservation maps full-volume and quota errors",
        arguments: [ENOSPC, EDQUOT]
    )
    func reserveMapsInsufficientStorage(_ code: Int32) async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        try inputData.write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess(
            supportsFileCloning: { _ in true },
            createTemporaryFile: { _, _ in
                errno = code
                return -1
            }
        )

        await expectError(.insufficientStorage) {
            try await access.reserveTemporaryOutput(fixture.plan)
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.temporaryURL.path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
    }

    @Test("Reservation preserves a temp-name replacement before unlink")
    func reserveRejectsAndPreservesPreUnlinkReplacement() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        let inputData = Data("original".utf8)
        let replacementData = Data("unrelated replacement".utf8)
        let temporaryURL = fixture.plan.temporaryURL
        try inputData.write(to: fixture.plan.inputURL)
        let access = SecurityScopedFileAccess(
            beforeTemporaryIdentityCheck: { _, _ in
                try FileManager.default.removeItem(at: temporaryURL)
                try replacementData.write(
                    to: temporaryURL,
                    options: .withoutOverwriting
                )
            }
        )

        await expectError(.temporaryOutputChanged) {
            try await access.reserveTemporaryOutput(fixture.plan)
        }

        #expect(try Data(contentsOf: fixture.plan.inputURL) == inputData)
        #expect(try Data(contentsOf: temporaryURL) == replacementData)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.finalURL.path
        ))
    }

    @Test("Descriptor mutation APIs reject a reservation without a lease")
    func descriptorMutationsRejectPlaceholderReservation() async throws {
        let fixture = try FilePlanFixture()
        defer { fixture.remove() }
        try Data("original".utf8).write(to: fixture.plan.inputURL)
        let identity = FileIdentity(device: 1, inode: 2)
        let placeholder = try TemporaryOutputReservation(
            plan: fixture.plan,
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: identity
            )
        )
        let producedMetadata = FileMetadata(
            byteCount: 1,
            isDirectory: false,
            identity: identity
        )
        let access = SecurityScopedFileAccess()

        await expectError(.temporaryOutputChanged) {
            try await access.commitWithoutReplacing(
                fixture.plan,
                reservation: placeholder,
                expectedTemporaryMetadata: producedMetadata
            )
        }
        await expectError(.temporaryOutputChanged) {
            try await access.cleanupTemporaryOutput(
                fixture.plan,
                reservation: placeholder,
                expectedTemporaryMetadata: producedMetadata
            )
        }
    }

    @Test("Reservation rejects a symbolic-link input or output directory")
    func reserveRejectsSymbolicLinkIdentities() async throws {
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
        let access = SecurityScopedFileAccess()

        await expectError(.symbolicLinkNotAllowed) {
            try await access.reserveTemporaryOutput(inputLinkFixture.plan)
        }

        let linkedDirectoryFixture = try LinkedOutputDirectoryFixture()
        defer { linkedDirectoryFixture.remove() }
        try Data("original".utf8).write(
            to: linkedDirectoryFixture.plan.inputURL
        )
        await expectError(.symbolicLinkNotAllowed) {
            try await access.reserveTemporaryOutput(
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

private final class TemporaryFileCreationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func create(_ directoryDescriptor: Int32, _ name: String) -> Int32 {
        lock.lock()
        calls += 1
        lock.unlock()
        errno = EIO
        return -1
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
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
