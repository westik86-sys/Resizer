import Combine
import Foundation

@MainActor
final class CompressionFeatureModel: ObservableObject {
    @Published private(set) var snapshot: CompressionSnapshot = .empty

    private let coordinator: CompressionCoordinator

    init(coordinator: CompressionCoordinator) {
        self.coordinator = coordinator
    }

    var jobs: [CompressionJob] {
        snapshot.jobs
    }

    @discardableResult
    func createJob(inputURL: URL) async throws -> CompressionJob {
        let job = try await coordinator.createJob(inputURL: inputURL)
        await refresh()
        return job
    }

    func refresh() async {
        snapshot = await coordinator.snapshot()
    }
}
