import Foundation
import Testing
@testable import Resizer

@Suite("App composition")
struct AppCompositionTests {
    @Test("System Downloads resolves its sandbox container link")
    @MainActor
    func systemDownloadsResolvesSandboxContainerLink() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let containerURL = rootURL.appendingPathComponent(
            "Container",
            isDirectory: true
        )
        let downloadsURL = rootURL.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let sandboxDownloadsURL = containerURL.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: downloadsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: sandboxDownloadsURL,
            withDestinationURL: downloadsURL
        )

        let resolvedURL = AppComposition
            .resolvedSystemDownloadsDirectoryURL(
                from: [sandboxDownloadsURL]
            )

        #expect(
            resolvedURL
                == downloadsURL.resolvingSymlinksInPath().standardizedFileURL
        )

        let fileAccess = SecurityScopedFileAccess()
        let unwrappedResolvedURL = try #require(resolvedURL)
        let metadata = try #require(
            await fileAccess.metadata(at: unwrappedResolvedURL)
        )
        #expect(metadata.isDirectory)

        do {
            _ = try await fileAccess.metadata(at: sandboxDownloadsURL)
            Issue.record("Expected the unresolved container link to fail")
        } catch let error as SecurityScopedFileAccessError {
            #expect(error == .symbolicLinkNotAllowed)
        }
    }

    @Test("Missing system Downloads candidate keeps the picker fallback")
    @MainActor
    func missingSystemDownloadsKeepsPickerFallback() {
        #expect(
            AppComposition.resolvedSystemDownloadsDirectoryURL(from: [])
                == nil
        )
    }
}
