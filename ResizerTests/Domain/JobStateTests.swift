import Testing
@testable import Resizer

@Suite("JobState transitions")
struct JobStateTests {
    @Test("Happy path reaches completed only through both finishing phases")
    func happyPath() throws {
        let states: [JobState] = [
            .draft,
            .probing,
            .ready,
            .queued,
            .running(progress: nil),
            .finishing(.validating),
            .finishing(.committing),
            .completed(try TestFixtures.result()),
        ]

        for (current, next) in zip(states, states.dropFirst()) {
            #expect(current.canTransition(to: next))
            #expect(try current.transitioning(to: next) == next)
        }
    }

    @Test("Concrete state matrix accepts exactly the documented edges")
    func transitionMatrix() throws {
        let result = try TestFixtures.result()
        let states: [(name: String, state: JobState)] = [
            ("draft", .draft),
            ("probing", .probing),
            ("ready", .ready),
            ("queued", .queued),
            ("running", .running(progress: nil)),
            ("validating", .finishing(.validating)),
            ("committing", .finishing(.committing)),
            ("cancelling", .cancelling(lastProgress: nil)),
            ("cancelled", .cancelled),
            ("completed", .completed(result)),
            ("failedProbe", .failed(TestFixtures.failure(stage: .probe))),
            ("failedPreflight", .failed(TestFixtures.failure(stage: .preflight))),
            ("failedEncode", .failed(TestFixtures.failure(stage: .encode))),
            ("failedValidate", .failed(TestFixtures.failure(stage: .validate))),
            ("failedCommit", .failed(TestFixtures.failure(stage: .commit))),
        ]
        let allowedEdges: Set<String> = [
            "draft->probing",
            "probing->ready",
            "probing->failedProbe",
            "ready->queued",
            "queued->running",
            "queued->failedPreflight",
            "running->validating",
            "running->cancelling",
            "running->failedEncode",
            "validating->committing",
            "validating->failedValidate",
            "committing->completed",
            "committing->failedCommit",
            "cancelling->cancelled",
            "cancelled->ready",
            "failedProbe->probing",
            "failedPreflight->ready",
            "failedEncode->ready",
            "failedValidate->ready",
            "failedCommit->ready",
        ]

        for current in states {
            for next in states {
                let edge = "\(current.name)->\(next.name)"
                let shouldAllow = allowedEdges.contains(edge)
                #expect(
                    current.state.canTransition(to: next.state) == shouldAllow,
                    "Unexpected transition decision for \(edge)"
                )

                do {
                    let transitioned = try current.state.transitioning(
                        to: next.state
                    )
                    if shouldAllow {
                        #expect(transitioned == next.state)
                    } else {
                        Issue.record("Expected \(edge) to throw")
                    }
                } catch let error as JobTransitionError {
                    if shouldAllow {
                        Issue.record("Expected \(edge) to succeed, got \(error)")
                    } else {
                        #expect(
                            error == JobTransitionError(
                                from: current.state.phase,
                                to: next.state.phase
                            )
                        )
                    }
                } catch {
                    Issue.record("Unexpected error for \(edge): \(error)")
                }
            }
        }
    }

    @Test("Cancellation wins after running enters cancelling")
    func cancellationPath() throws {
        let progress = try TestFixtures.progress()
        let running = JobState.running(progress: progress)
        let cancelling = JobState.cancelling(lastProgress: progress)

        #expect(running.canTransition(to: cancelling))
        #expect(cancelling.canTransition(to: .cancelled))
        #expect(!cancelling.canTransition(to: .finishing(.validating)))
        #expect(!cancelling.canTransition(
            to: .completed(try TestFixtures.result())
        ))
        #expect(!cancelling.canTransition(
            to: .failed(TestFixtures.failure(stage: .encode))
        ))
    }

    @Test("Failure stage determines its retry preparation level")
    func failureRetryTargets() {
        let probeFailure = JobState.failed(
            TestFixtures.failure(stage: .probe)
        )
        let encodeFailure = JobState.failed(
            TestFixtures.failure(stage: .encode)
        )

        #expect(JobState.probing.canTransition(to: probeFailure))
        #expect(probeFailure.canTransition(to: .probing))
        #expect(!probeFailure.canTransition(to: .ready))

        #expect(JobState.running(progress: nil).canTransition(to: encodeFailure))
        #expect(encodeFailure.canTransition(to: .ready))
        #expect(!encodeFailure.canTransition(to: .probing))
    }

    @Test("Failure stage must match the source phase")
    func mismatchedFailureStages() {
        #expect(!JobState.probing.canTransition(
            to: .failed(TestFixtures.failure(stage: .commit))
        ))
        #expect(!JobState.queued.canTransition(
            to: .failed(TestFixtures.failure(stage: .encode))
        ))
        #expect(!JobState.finishing(.validating).canTransition(
            to: .failed(TestFixtures.failure(stage: .commit))
        ))
        #expect(!JobState.finishing(.committing).canTransition(
            to: .failed(TestFixtures.failure(stage: .validate))
        ))
    }
}
