import Foundation
import Testing

@Suite("Domain dependency boundary")
struct DomainBoundaryTests {
    @Test("Domain source does not import UI or reference Foundation.Process")
    func forbiddenDependenciesAreAbsent() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let domainURL = repositoryRoot.appendingPathComponent(
            "Resizer/Domain",
            isDirectory: true
        )

        guard let enumerator = FileManager.default.enumerator(
            at: domainURL,
            includingPropertiesForKeys: nil
        ) else {
            throw DomainBoundaryTestError.cannotEnumerateDomain
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift"
        }

        #expect(!files.isEmpty)
        let forbiddenPatterns: [(pattern: String, description: String)] = [
            (
                #"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*import(?:\s+(?:typealias|struct|class|enum|protocol|let|var|func))?\s+(?:SwiftUI|AppKit|Cocoa)(?:\.|\s|$)"#,
                "imports a UI framework"
            ),
            (#"\bProcess\b"#, "references Process"),
        ]

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in forbiddenPatterns {
                #expect(
                    source.range(
                        of: forbidden.pattern,
                        options: .regularExpression
                    ) == nil,
                    "\(file.lastPathComponent) \(forbidden.description)"
                )
            }
        }
    }
}

private enum DomainBoundaryTestError: Error {
    case cannotEnumerateDomain
}
