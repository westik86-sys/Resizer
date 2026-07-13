import Foundation

final class FFprobeFixtureBundleToken: NSObject {}

nonisolated enum FFprobeFixtureError: Error, Sendable, Equatable {
    case unavailable(String)
}

nonisolated enum FFprobeFixture {
    static func data(named name: String) throws -> Data {
        guard let bundledURL = bundledURL(named: name) else {
            throw FFprobeFixtureError.unavailable(name)
        }
        return try Data(contentsOf: bundledURL)
    }

    private static func bundledURL(named name: String) -> URL? {
        let bundle = Bundle(for: FFprobeFixtureBundleToken.self)
        return bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/FFprobe"
        ) ?? bundle.url(forResource: name, withExtension: "json")
    }

}
