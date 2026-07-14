import Darwin
import Foundation

nonisolated enum SecurityScopedFileAccessError: Error, Sendable, Equatable {
    case invalidURL
    case invalidOutputPlan
    case inputMissing
    case temporaryOutputMissing
    case temporaryOutputAlreadyExists
    case outputDirectoryMissing
    case finalOutputAlreadyExists
    case temporaryOutputChanged
    case symbolicLinkNotAllowed
    case unsupportedFileType
    case inputOutputAlias
    case metadataReadFailed
    case reservationFailed
    case commitFailed
    case cleanupFailed
}

/// Provides the narrow file-system operations used by the headless workflow.
///
/// The value is stateless so overlapping callers retain and release their own
/// security scopes independently. A scope is released only when its matching
/// `startAccessingSecurityScopedResource` call returned `true`; `false` can
/// also mean that the process already has access to the URL.
nonisolated struct SecurityScopedFileAccess: FileAccessing, Sendable {
    typealias StartAccessing = @Sendable (URL) -> Bool
    typealias StopAccessing = @Sendable (URL) -> Void

    private let startAccessing: StartAccessing
    private let stopAccessing: StopAccessing

    init(
        startAccessing: @escaping StartAccessing = { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping StopAccessing = { url in
            url.stopAccessingSecurityScopedResource()
        }
    ) {
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let uniqueURLs = try Self.uniqueValidatedURLs(selectedURLs)
        var startedURLs: [URL] = []

        for url in uniqueURLs where startAccessing(url) {
            startedURLs.append(url)
        }

        defer {
            for url in startedURLs.reversed() {
                stopAccessing(url)
            }
        }

        return try await operation()
    }

    func metadata(at url: URL) async throws -> FileMetadata? {
        guard Self.isValidLocalAbsoluteURL(url) else {
            throw SecurityScopedFileAccessError.invalidURL
        }

        let entry: LocalFileEntry?
        do {
            entry = try Self.entry(at: url.standardizedFileURL)
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
        }

        guard let entry else {
            return nil
        }

        switch entry.kind {
        case .regular:
            return Self.metadata(for: entry, isDirectory: false)
        case .directory:
            return Self.metadata(for: entry, isDirectory: true)
        case .symbolicLink:
            throw SecurityScopedFileAccessError.symbolicLinkNotAllowed
        case .other:
            throw SecurityScopedFileAccessError.unsupportedFileType
        }
    }

    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) async throws -> TemporaryOutputReservation {
        let validatedPlan = try Self.validate(plan)
        let inputEntry = try Self.requiredRegularEntry(
            at: validatedPlan.inputURL,
            missingError: .inputMissing
        )
        try Self.requireOutputDirectory(validatedPlan.outputDirectoryURL)

        let temporaryEntry: LocalFileEntry
        do {
            temporaryEntry = try Self.createExclusiveRegularFile(
                at: validatedPlan.temporaryURL
            )
        } catch let failure as LocalFileSystemFailure {
            if failure.code == EEXIST {
                throw SecurityScopedFileAccessError
                    .temporaryOutputAlreadyExists
            }
            throw SecurityScopedFileAccessError.reservationFailed
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.reservationFailed
        }

        guard inputEntry.identity != temporaryEntry.identity else {
            throw SecurityScopedFileAccessError.inputOutputAlias
        }
        let metadata = Self.metadata(
            for: temporaryEntry,
            isDirectory: false
        )
        do {
            return try TemporaryOutputReservation(
                plan: plan,
                metadata: metadata
            )
        } catch {
            throw SecurityScopedFileAccessError.reservationFailed
        }
    }

    /// Convenience entry point for direct adapter callers. The application
    /// workflow uses the identity-carrying overload so validation and commit
    /// are bound to the same temporary inode.
    func commitWithoutReplacing(_ plan: OutputPlan) async throws {
        let validatedPlan = try Self.validate(plan)
        let temporaryEntry = try Self.requiredRegularEntry(
            at: validatedPlan.temporaryURL,
            missingError: .temporaryOutputMissing
        )
        try await commitWithoutReplacing(
            plan,
            expectedTemporaryMetadata: Self.metadata(
                for: temporaryEntry,
                isDirectory: false
            )
        )
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        let validatedPlan = try Self.validate(plan)
        let inputEntry = try Self.requiredRegularEntry(
            at: validatedPlan.inputURL,
            missingError: .inputMissing
        )
        let temporaryEntry = try Self.requiredRegularEntry(
            at: validatedPlan.temporaryURL,
            missingError: .temporaryOutputMissing
        )
        guard !expectedTemporaryMetadata.isDirectory,
              expectedTemporaryMetadata.identity != nil,
              Self.metadata(for: temporaryEntry, isDirectory: false)
                == expectedTemporaryMetadata else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }
        try Self.requireOutputDirectory(validatedPlan.outputDirectoryURL)

        do {
            if try Self.entry(at: validatedPlan.finalURL) != nil {
                throw SecurityScopedFileAccessError.finalOutputAlreadyExists
            }
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.commitFailed
        }
        guard inputEntry.identity != temporaryEntry.identity else {
            throw SecurityScopedFileAccessError.inputOutputAlias
        }

        do {
            try Self.renameExclusively(
                from: validatedPlan.temporaryURL,
                to: validatedPlan.finalURL
            )
            let publishedEntry = try Self.requiredRegularEntry(
                at: validatedPlan.finalURL,
                missingError: .temporaryOutputChanged
            )
            guard Self.matchesPublishedEntry(
                publishedEntry,
                expected: expectedTemporaryMetadata
            ) else {
                throw SecurityScopedFileAccessError.temporaryOutputChanged
            }
        } catch let failure as LocalFileSystemFailure {
            switch failure.code {
            case EEXIST:
                throw SecurityScopedFileAccessError.finalOutputAlreadyExists
            case ENOENT, ENOTDIR:
                throw SecurityScopedFileAccessError.temporaryOutputMissing
            default:
                throw SecurityScopedFileAccessError.commitFailed
            }
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.commitFailed
        }
    }

    /// Convenience entry point retained for direct adapter callers. It is
    /// deliberately fail-closed for an existing path because unsealed cleanup
    /// cannot prove that the inode belongs to this job.
    func cleanupTemporaryOutput(_ plan: OutputPlan) async throws {
        try await cleanupTemporaryOutput(
            plan,
            expectedTemporaryMetadata: nil
        )
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        let validatedPlan = try Self.validate(plan)

        let temporaryEntry: LocalFileEntry?
        do {
            temporaryEntry = try Self.entry(at: validatedPlan.temporaryURL)
        } catch {
            throw SecurityScopedFileAccessError.cleanupFailed
        }
        guard let temporaryEntry else {
            return
        }
        try Self.requireRegularFile(temporaryEntry)
        guard let expectedTemporaryMetadata,
              !expectedTemporaryMetadata.isDirectory,
              let expectedIdentity = expectedTemporaryMetadata.identity,
              temporaryEntry.identity == expectedIdentity else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }
        try Self.requireOutputDirectory(validatedPlan.outputDirectoryURL)

        do {
            if let inputEntry = try Self.entry(at: validatedPlan.inputURL) {
                try Self.requireRegularFile(inputEntry)
                guard inputEntry.identity != temporaryEntry.identity else {
                    throw SecurityScopedFileAccessError.inputOutputAlias
                }
            }
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.cleanupFailed
        }

        do {
            try Self.unlink(validatedPlan.temporaryURL)
        } catch let failure as LocalFileSystemFailure
            where failure.code == ENOENT || failure.code == ENOTDIR {
            return
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.cleanupFailed
        }
    }

    private static func uniqueValidatedURLs(_ urls: [URL]) throws -> [URL] {
        var seenPaths: Set<String> = []
        var result: [URL] = []

        for url in urls {
            guard isValidLocalAbsoluteURL(url) else {
                throw SecurityScopedFileAccessError.invalidURL
            }

            let key = url.standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                // Retain the original URL: it may carry a security scope that a
                // newly constructed or transformed URL would not retain.
                result.append(url)
            }
        }
        return result
    }

    private static func validate(_ plan: OutputPlan) throws -> ValidatedPlan {
        guard isValidLocalAbsoluteURL(plan.inputURL),
              isValidLocalAbsoluteURL(plan.temporaryURL),
              isValidLocalAbsoluteURL(plan.finalURL) else {
            throw SecurityScopedFileAccessError.invalidOutputPlan
        }

        let inputURL = plan.inputURL.standardizedFileURL
        let temporaryURL = plan.temporaryURL.standardizedFileURL
        let finalURL = plan.finalURL.standardizedFileURL
        let outputDirectoryURL = temporaryURL.deletingLastPathComponent()
        let jobToken = plan.jobID.uuidString.lowercased()
        let temporaryName = temporaryURL.lastPathComponent.lowercased()

        guard inputURL != temporaryURL,
              inputURL != finalURL,
              temporaryURL != finalURL,
              finalURL.deletingLastPathComponent() == outputDirectoryURL,
              temporaryURL.pathExtension.lowercased() == "mp4",
              finalURL.pathExtension.lowercased() == "mp4",
              temporaryName.contains(jobToken),
              temporaryName.hasSuffix(".partial.mp4") else {
            throw SecurityScopedFileAccessError.invalidOutputPlan
        }

        let resolvedInputURL = inputURL.resolvingSymlinksInPath()
        let resolvedOutputDirectoryURL = outputDirectoryURL
            .resolvingSymlinksInPath()
        let resolvedTemporaryURL = resolvedOutputDirectoryURL
            .appendingPathComponent(temporaryURL.lastPathComponent)
        let resolvedFinalURL = resolvedOutputDirectoryURL
            .appendingPathComponent(finalURL.lastPathComponent)
        guard resolvedInputURL != resolvedTemporaryURL,
              resolvedInputURL != resolvedFinalURL,
              resolvedTemporaryURL != resolvedFinalURL else {
            throw SecurityScopedFileAccessError.inputOutputAlias
        }

        return ValidatedPlan(
            inputURL: inputURL,
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            outputDirectoryURL: outputDirectoryURL
        )
    }

    private static func requiredRegularEntry(
        at url: URL,
        missingError: SecurityScopedFileAccessError
    ) throws -> LocalFileEntry {
        let value: LocalFileEntry?
        do {
            value = try entry(at: url)
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
        }
        guard let value else {
            throw missingError
        }
        try requireRegularFile(value)
        return value
    }

    private static func requireOutputDirectory(_ url: URL) throws {
        let value: LocalFileEntry?
        do {
            value = try entry(at: url)
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
        }
        guard let value else {
            throw SecurityScopedFileAccessError.outputDirectoryMissing
        }
        switch value.kind {
        case .directory:
            return
        case .symbolicLink:
            throw SecurityScopedFileAccessError.symbolicLinkNotAllowed
        case .regular, .other:
            throw SecurityScopedFileAccessError.unsupportedFileType
        }
    }

    private static func requireRegularFile(_ entry: LocalFileEntry) throws {
        switch entry.kind {
        case .regular:
            return
        case .symbolicLink:
            throw SecurityScopedFileAccessError.symbolicLinkNotAllowed
        case .directory, .other:
            throw SecurityScopedFileAccessError.unsupportedFileType
        }
    }

    private static func entry(at url: URL) throws -> LocalFileEntry? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        guard result != 0 else {
            let mode = mode_t(status.st_mode) & mode_t(S_IFMT)
            let kind: LocalFileEntry.Kind
            switch mode {
            case mode_t(S_IFREG):
                kind = .regular
            case mode_t(S_IFDIR):
                kind = .directory
            case mode_t(S_IFLNK):
                kind = .symbolicLink
            default:
                kind = .other
            }
            return LocalFileEntry(
                kind: kind,
                byteCount: Int64(status.st_size),
                identity: FileIdentity(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                ),
                modificationTimeNanoseconds: timeNanoseconds(
                    status.st_mtimespec
                ),
                statusChangeTimeNanoseconds: timeNanoseconds(
                    status.st_ctimespec
                )
            )
        }

        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return nil
        }
        throw LocalFileSystemFailure(code: code)
    }

    private static func createExclusiveRegularFile(
        at url: URL
    ) throws -> LocalFileEntry {
        var invalidRepresentation = false
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                invalidRepresentation = true
                return Int32(-1)
            }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard !invalidRepresentation else {
            throw SecurityScopedFileAccessError.invalidURL
        }
        guard descriptor >= 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
        guard mode_t(status.st_mode) & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              status.st_size == 0 else {
            throw SecurityScopedFileAccessError.unsupportedFileType
        }
        return LocalFileEntry(
            kind: .regular,
            byteCount: 0,
            identity: FileIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            modificationTimeNanoseconds: timeNanoseconds(
                status.st_mtimespec
            ),
            statusChangeTimeNanoseconds: timeNanoseconds(
                status.st_ctimespec
            )
        )
    }

    private static func renameExclusively(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        var invalidRepresentation = false
        let result = sourceURL.withUnsafeFileSystemRepresentation { source in
            guard let source else {
                invalidRepresentation = true
                return Int32(-1)
            }
            return destinationURL.withUnsafeFileSystemRepresentation {
                destination in
                guard let destination else {
                    invalidRepresentation = true
                    return Int32(-1)
                }
                return Darwin.renameatx_np(
                    AT_FDCWD,
                    source,
                    AT_FDCWD,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard !invalidRepresentation else {
            throw SecurityScopedFileAccessError.invalidURL
        }
        guard result == 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
    }

    private static func unlink(_ url: URL) throws {
        var invalidRepresentation = false
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                invalidRepresentation = true
                return Int32(-1)
            }
            return Darwin.unlink(path)
        }
        guard !invalidRepresentation else {
            throw SecurityScopedFileAccessError.invalidURL
        }
        guard result == 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
    }

    private static func isValidLocalAbsoluteURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.path.hasPrefix("/")
            && !url.path.contains("\0")
    }

    private static func metadata(
        for entry: LocalFileEntry,
        isDirectory: Bool
    ) -> FileMetadata {
        FileMetadata(
            byteCount: max(0, entry.byteCount),
            isDirectory: isDirectory,
            identity: entry.identity,
            modificationTimeNanoseconds: entry.modificationTimeNanoseconds,
            statusChangeTimeNanoseconds: entry.statusChangeTimeNanoseconds
        )
    }

    private static func timeNanoseconds(_ value: timespec) -> Int64? {
        let seconds = Int64(value.tv_sec)
        let nanoseconds = Int64(value.tv_nsec)
        let (scaledSeconds, multiplicationOverflow) = seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (result, additionOverflow) = scaledSeconds
            .addingReportingOverflow(nanoseconds)
        guard !multiplicationOverflow, !additionOverflow else {
            return nil
        }
        return result
    }

    private static func matchesPublishedEntry(
        _ entry: LocalFileEntry,
        expected: FileMetadata
    ) -> Bool {
        entry.identity == expected.identity
            && max(0, entry.byteCount) == expected.byteCount
            && entry.modificationTimeNanoseconds
                == expected.modificationTimeNanoseconds
    }
}

private nonisolated struct ValidatedPlan: Sendable {
    let inputURL: URL
    let temporaryURL: URL
    let finalURL: URL
    let outputDirectoryURL: URL
}

private nonisolated struct LocalFileEntry: Sendable {
    enum Kind: Sendable {
        case regular
        case directory
        case symbolicLink
        case other
    }

    let kind: Kind
    let byteCount: Int64
    let identity: FileIdentity
    let modificationTimeNanoseconds: Int64?
    let statusChangeTimeNanoseconds: Int64?
}

private nonisolated struct LocalFileSystemFailure: Error, Sendable {
    let code: Int32
}
