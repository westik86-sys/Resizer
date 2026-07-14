import AppKit

/// Delays normal application termination until the compression coordinator
/// has cancelled and reaped every child process and completed exact cleanup.
/// Force Quit remains an operating-system escape hatch and cannot provide
/// cleanup guarantees.
@MainActor
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    typealias ShutdownAction = @MainActor @Sendable () async -> Void
    typealias TerminationReply = @MainActor @Sendable (
        NSApplication,
        Bool
    ) -> Void

    private let terminationReply: TerminationReply
    private var shutdownAction: ShutdownAction?
    private var terminationTask: Task<Void, Never>?

    override convenience init() {
        self.init { application, shouldTerminate in
            application.reply(
                toApplicationShouldTerminate: shouldTerminate
            )
        }
    }

    init(terminationReply: @escaping TerminationReply) {
        self.terminationReply = terminationReply
        super.init()
    }

    func installShutdownAction(
        _ action: @escaping ShutdownAction
    ) {
        shutdownAction = action
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let shutdownAction else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { [weak self, terminationReply] in
            await shutdownAction()
            guard let self else { return }
            self.terminationTask = nil
            terminationReply(sender, true)
        }
        return .terminateLater
    }
}
