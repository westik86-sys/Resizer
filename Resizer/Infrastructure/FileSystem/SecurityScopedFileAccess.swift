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
    case unsupportedOutputFileSystem
    case insufficientStorage
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
    typealias SupportsFileCloning = @Sendable (Int32) throws -> Bool
    typealias CreateTemporaryFile = @Sendable (Int32, String) -> Int32
    typealias SynchronizeFile = @Sendable (Int32) -> Int32
    typealias CloneFile = @Sendable (Int32, Int32, String) -> Int32
    typealias BeforeTemporaryIdentityCheck =
        @Sendable (Int32, String) throws -> Void

    private let startAccessing: StartAccessing
    private let stopAccessing: StopAccessing
    private let supportsFileCloning: SupportsFileCloning
    private let createTemporaryFile: CreateTemporaryFile
    private let synchronizeFile: SynchronizeFile
    private let cloneFile: CloneFile
    private let beforeTemporaryIdentityCheck: BeforeTemporaryIdentityCheck

    init(
        startAccessing: @escaping StartAccessing = { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping StopAccessing = { url in
            url.stopAccessingSecurityScopedResource()
        },
        supportsFileCloning: @escaping SupportsFileCloning = { descriptor in
            try SecurityScopedFileAccess.volumeSupportsFileCloning(descriptor)
        },
        createTemporaryFile:
            @escaping CreateTemporaryFile = { descriptor, name in
                name.withCString { pointer in
                    Darwin.openat(
                        descriptor,
                        pointer,
                        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
            },
        synchronizeFile: @escaping SynchronizeFile = { descriptor in
            Darwin.fsync(descriptor)
        },
        cloneFile: @escaping CloneFile = { source, directory, finalName in
            finalName.withCString { pointer in
                Darwin.fclonefileat(source, directory, pointer, 0)
            }
        },
        beforeTemporaryIdentityCheck:
            @escaping BeforeTemporaryIdentityCheck = { _, _ in
        }
    ) {
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.supportsFileCloning = supportsFileCloning
        self.createTemporaryFile = createTemporaryFile
        self.synchronizeFile = synchronizeFile
        self.cloneFile = cloneFile
        self.beforeTemporaryIdentityCheck = beforeTemporaryIdentityCheck
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

    func metadata(
        for reservation: TemporaryOutputReservation
    ) async throws -> FileMetadata? {
        guard let descriptor = reservation.lease.fileDescriptor else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        do {
            let entry = try Self.entry(forDescriptor: descriptor)
            try Self.requireRegularFile(entry)
            return Self.metadata(for: entry, isDirectory: false)
        } catch let error as SecurityScopedFileAccessError {
            throw error
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
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
        let lease: TemporaryOutputLease
        do {
            (temporaryEntry, lease) = try Self
                .createReservedTemporaryOutput(
                    temporaryURL: validatedPlan.temporaryURL,
                    outputDirectoryURL: validatedPlan.outputDirectoryURL,
                    supportsFileCloning: supportsFileCloning,
                    createTemporaryFile: createTemporaryFile,
                    beforeIdentityCheck: beforeTemporaryIdentityCheck
                )
        } catch let failure as LocalFileSystemFailure {
            if failure.code == EEXIST {
                throw SecurityScopedFileAccessError
                    .temporaryOutputAlreadyExists
            }
            if Self.isInsufficientStorage(failure.code) {
                throw SecurityScopedFileAccessError.insufficientStorage
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
                metadata: metadata,
                lease: lease
            )
        } catch {
            throw SecurityScopedFileAccessError.reservationFailed
        }
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        let validatedPlan = try Self.validate(plan)
        guard reservation.jobID == plan.jobID,
              reservation.temporaryURL
                == validatedPlan.temporaryURL.standardizedFileURL,
              let fileDescriptor = reservation.lease.fileDescriptor,
              let directoryDescriptor = reservation.lease
                .directoryDescriptor else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        let inputEntry = try Self.requiredRegularEntry(
            at: validatedPlan.inputURL,
            missingError: .inputMissing
        )
        let temporaryEntry: LocalFileEntry
        let heldDirectoryEntry: LocalFileEntry
        do {
            temporaryEntry = try Self.entry(forDescriptor: fileDescriptor)
            heldDirectoryEntry = try Self.entry(
                forDescriptor: directoryDescriptor
            )
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
        }
        try Self.requireRegularFile(temporaryEntry)
        guard heldDirectoryEntry.kind == .directory else {
            throw SecurityScopedFileAccessError.outputDirectoryMissing
        }

        let currentMetadata = Self.metadata(
            for: temporaryEntry,
            isDirectory: false
        )
        guard !expectedTemporaryMetadata.isDirectory,
              expectedTemporaryMetadata.byteCount > 0,
              currentMetadata == expectedTemporaryMetadata,
              inputEntry.identity != temporaryEntry.identity else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        let pathDirectory = try Self.requiredDirectoryEntry(
            at: validatedPlan.outputDirectoryURL
        )
        guard pathDirectory.identity == heldDirectoryEntry.identity else {
            throw SecurityScopedFileAccessError.outputDirectoryMissing
        }

        guard temporaryEntry.linkCount == 0 else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }
        try Task.checkCancellation()
        try synchronizeForCommit(fileDescriptor)
        try Task.checkCancellation()
        try publishClone(
            fileDescriptor: fileDescriptor,
            directoryDescriptor: directoryDescriptor,
            finalName: validatedPlan.finalURL.lastPathComponent
        )
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        let validatedPlan = try Self.validate(plan)
        guard reservation.jobID == plan.jobID,
              reservation.temporaryURL
                == validatedPlan.temporaryURL.standardizedFileURL else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        guard let descriptor = reservation.lease.fileDescriptor,
              let directoryDescriptor = reservation.lease.directoryDescriptor else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        let entry: LocalFileEntry
        do {
            entry = try Self.entry(forDescriptor: descriptor)
        } catch {
            throw SecurityScopedFileAccessError.cleanupFailed
        }
        try Self.requireRegularFile(entry)
        if let expectedIdentity = expectedTemporaryMetadata?.identity,
           entry.identity != expectedIdentity {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }

        guard entry.linkCount == 0 else {
            throw SecurityScopedFileAccessError.temporaryOutputChanged
        }
        _ = directoryDescriptor
    }

    private func publishClone(
        fileDescriptor: Int32,
        directoryDescriptor: Int32,
        finalName: String
    ) throws {
        let result = cloneFile(
            fileDescriptor,
            directoryDescriptor,
            finalName
        )
        guard result == 0 else {
            let code = errno
            switch code {
            case EEXIST:
                throw SecurityScopedFileAccessError.finalOutputAlreadyExists
            default:
                throw Self.commitError(forErrno: code)
            }
        }
    }

    private func synchronizeForCommit(_ descriptor: Int32) throws {
        while true {
            if synchronizeFile(descriptor) == 0 {
                return
            }
            let code = errno
            if code != EINTR {
                throw Self.commitError(forErrno: code)
            }
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

    private static func requiredDirectoryEntry(
        at url: URL
    ) throws -> LocalFileEntry {
        let value: LocalFileEntry?
        do {
            value = try entry(at: url)
        } catch {
            throw SecurityScopedFileAccessError.metadataReadFailed
        }
        guard let value else {
            throw SecurityScopedFileAccessError.outputDirectoryMissing
        }
        guard value.kind == .directory else {
            if value.kind == .symbolicLink {
                throw SecurityScopedFileAccessError.symbolicLinkNotAllowed
            }
            throw SecurityScopedFileAccessError.unsupportedFileType
        }
        return value
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
            return entry(from: status)
        }

        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return nil
        }
        throw LocalFileSystemFailure(code: code)
    }

    private static func entry(
        forDescriptor descriptor: Int32
    ) throws -> LocalFileEntry {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
        return entry(from: status)
    }

    private static func entry(
        named name: String,
        relativeTo directoryDescriptor: Int32
    ) throws -> LocalFileEntry? {
        var status = stat()
        let result = name.withCString { namePointer in
            Darwin.fstatat(
                directoryDescriptor,
                namePointer,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result != 0 else {
            return entry(from: status)
        }

        let code = errno
        if code == ENOENT || code == ENOTDIR {
            return nil
        }
        throw LocalFileSystemFailure(code: code)
    }

    private static func entry(from status: stat) -> LocalFileEntry {
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
            linkCount: UInt64(status.st_nlink),
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

    private static func createReservedTemporaryOutput(
        temporaryURL: URL,
        outputDirectoryURL: URL,
        supportsFileCloning: SupportsFileCloning,
        createTemporaryFile: CreateTemporaryFile,
        beforeIdentityCheck: BeforeTemporaryIdentityCheck
    ) throws -> (LocalFileEntry, TemporaryOutputLease) {
        var invalidRepresentation = false
        let directoryDescriptor = outputDirectoryURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    invalidRepresentation = true
                    return Int32(-1)
                }
                return Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        guard !invalidRepresentation else {
            throw SecurityScopedFileAccessError.invalidURL
        }
        guard directoryDescriptor >= 0 else {
            throw LocalFileSystemFailure(code: errno)
        }

        do {
            let directoryEntry = try entry(
                forDescriptor: directoryDescriptor
            )
            guard directoryEntry.kind == .directory else {
                throw SecurityScopedFileAccessError.unsupportedFileType
            }
            guard try supportsFileCloning(directoryDescriptor) else {
                throw SecurityScopedFileAccessError
                    .unsupportedOutputFileSystem
            }
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }

        let temporaryName = temporaryURL.lastPathComponent
        let fileDescriptor = createTemporaryFile(
            directoryDescriptor,
            temporaryName
        )
        guard fileDescriptor >= 0 else {
            let code = errno
            Darwin.close(directoryDescriptor)
            throw LocalFileSystemFailure(code: code)
        }

        do {
            let createdEntry = try entry(forDescriptor: fileDescriptor)
            guard createdEntry.kind == .regular,
                  createdEntry.byteCount == 0,
                  createdEntry.linkCount == 1 else {
                throw SecurityScopedFileAccessError.unsupportedFileType
            }
            // A no-op in production. Tests use this narrow seam to prove that
            // the following descriptor-relative identity guard rejects a name
            // replaced after openat without deleting the replacement.
            try beforeIdentityCheck(directoryDescriptor, temporaryName)
            let namedEntry = try entry(
                named: temporaryName,
                relativeTo: directoryDescriptor
            )
            guard let namedEntry,
                  namedEntry.kind == .regular,
                  namedEntry.identity == createdEntry.identity,
                  namedEntry.byteCount == 0,
                  namedEntry.linkCount == 1 else {
                throw SecurityScopedFileAccessError.temporaryOutputChanged
            }

            // Darwin has no conditional unlink-by-inode primitive. The unique
            // job name, descriptor-relative identity check, and immediate
            // post-unlink link-count seal keep the staging descriptor anonymous
            // before it leaves this synchronous reservation boundary.
            let unlinkResult = temporaryName.withCString { name in
                Darwin.unlinkat(directoryDescriptor, name, 0)
            }
            guard unlinkResult == 0 else {
                throw LocalFileSystemFailure(code: errno)
            }

            // Removing the entry updates inode metadata (notably ctime).
            // Seal the descriptor only after it is anonymous.
            let temporaryEntry = try entry(forDescriptor: fileDescriptor)
            guard temporaryEntry.kind == .regular,
                  temporaryEntry.identity == createdEntry.identity,
                  temporaryEntry.byteCount == 0,
                  temporaryEntry.linkCount == 0 else {
                throw SecurityScopedFileAccessError.temporaryOutputChanged
            }

            let lease = try TemporaryOutputLease(
                ownedFileDescriptor: fileDescriptor,
                ownedDirectoryDescriptor: directoryDescriptor
            )
            return (temporaryEntry, lease)
        } catch {
            // If the name changed before anonymous sealing, fail closed and do
            // not unlink by pathname: that entry may belong to another actor.
            Darwin.close(fileDescriptor)
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    private static func volumeSupportsFileCloning(
        _ descriptor: Int32
    ) throws -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr =
            attrgroup_t(ATTR_VOL_INFO)
            | attrgroup_t(ATTR_VOL_CAPABILITIES)

        var buffer = VolumeCapabilitiesBuffer()
        let result = Darwin.fgetattrlist(
            descriptor,
            &attributes,
            &buffer,
            MemoryLayout<VolumeCapabilitiesBuffer>.size,
            0
        )
        guard result == 0 else {
            throw LocalFileSystemFailure(code: errno)
        }
        guard buffer.length
            >= UInt32(MemoryLayout<VolumeCapabilitiesBuffer>.size) else {
            throw LocalFileSystemFailure(code: EIO)
        }

        let cloneCapability = UInt32(VOL_CAP_INT_CLONE)
        return buffer.capabilities.valid.1 & cloneCapability == cloneCapability
            && buffer.capabilities.capabilities.1 & cloneCapability
                == cloneCapability
    }

    private static func isInsufficientStorage(_ code: Int32) -> Bool {
        code == ENOSPC || code == EDQUOT
    }

    private static func commitError(
        forErrno code: Int32
    ) -> SecurityScopedFileAccessError {
        isInsufficientStorage(code) ? .insufficientStorage : .commitFailed
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
}

private nonisolated struct ValidatedPlan: Sendable {
    let inputURL: URL
    let temporaryURL: URL
    let finalURL: URL
    let outputDirectoryURL: URL
}

private nonisolated struct LocalFileEntry: Sendable {
    enum Kind: Sendable, Equatable {
        case regular
        case directory
        case symbolicLink
        case other
    }

    let kind: Kind
    let byteCount: Int64
    let linkCount: UInt64
    let identity: FileIdentity
    let modificationTimeNanoseconds: Int64?
    let statusChangeTimeNanoseconds: Int64?
}

private nonisolated struct VolumeCapabilitiesBuffer {
    var length: UInt32 = 0
    var capabilities = vol_capabilities_attr_t()
}

private nonisolated struct LocalFileSystemFailure: Error, Sendable {
    let code: Int32
}
