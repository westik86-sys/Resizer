import AppKit
import Testing
@testable import Resizer

@Suite("Application termination")
@MainActor
struct ApplicationLifecycleDelegateTests {
    @Test("Termination is immediate when no workflow was installed")
    func immediateWithoutWorkflow() {
        let delegate = ApplicationLifecycleDelegate { _, _ in }

        #expect(
            delegate.applicationShouldTerminate(.shared)
                == .terminateNow
        )
    }

    @Test("Termination waits for asynchronous workflow shutdown")
    func waitsForShutdownBarrier() async throws {
        let gate = LifecycleShutdownGate()
        let replies = LifecycleReplyRecorder()
        let delegate = ApplicationLifecycleDelegate {
            _, shouldTerminate in
            replies.record(shouldTerminate)
        }
        delegate.installShutdownAction {
            await gate.wait()
        }

        #expect(
            delegate.applicationShouldTerminate(.shared)
                == .terminateLater
        )
        #expect(replies.values.isEmpty)
        #expect(
            delegate.applicationShouldTerminate(.shared)
                == .terminateLater
        )

        await gate.open()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while replies.values.isEmpty {
            guard clock.now < deadline else {
                Issue.record("Termination reply timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(replies.values == [true])
    }
}

@MainActor
private final class LifecycleReplyRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

private actor LifecycleShutdownGate {
    private var isOpen = false

    func wait() async {
        while !isOpen {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }
}
