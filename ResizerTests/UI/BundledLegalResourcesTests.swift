import Foundation
import Testing
@testable import Resizer

@Suite("Bundled legal resources")
struct BundledLegalResourcesTests {
    @Test("FFmpeg notices and LGPL texts are present in the app bundle")
    func resourcesAreBundled() throws {
        let notices = try resource(
            name: "THIRD_PARTY_NOTICES",
            fileExtension: "md"
        )
        let lgpl21 = try resource(
            name: "COPYING.LGPLv2.1",
            fileExtension: "txt"
        )
        let lgpl3 = try resource(
            name: "COPYING.LGPLv3",
            fileExtension: "txt"
        )

        #expect(notices.contains("FFmpeg 8.1.2"))
        #expect(notices.contains("GNU Lesser General"))
        #expect(notices.contains("Public License, version 2.1 or later"))
        #expect(notices.contains("Scripts/build-ffmpeg.sh"))
        #expect(lgpl21.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        #expect(lgpl3.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    }

    private func resource(
        name: String,
        fileExtension: String
    ) throws -> String {
        let url = try #require(
            Bundle.main.url(
                forResource: name,
                withExtension: fileExtension
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
