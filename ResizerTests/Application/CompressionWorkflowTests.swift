import Foundation
import Testing
@testable import Resizer

@Suite("Headless compression workflow")
struct CompressionWorkflowTests {
    @Test("Preparation admits video-only while preflight checks captured audio")
    func audioCapabilityIsDeferredToCapturedRecipePreflight() async throws {
        let harness = try await WorkflowHarness.make()

        let ready = try await harness.coordinator.prepare(
            jobID: harness.jobID
        )

        #expect(ready.state == .ready)
        let admissionRecipes = await harness.transcoder
            .observedCapabilityRecipes()
        let admissionRecipe = try #require(admissionRecipes.first)
        #expect(admissionRecipes.count == 1)
        #expect(
            admissionRecipe.origin == .primary(.quick(audio: .remove))
        )
        #expect(admissionRecipe.audioPolicy == .remove)

        _ = try await harness.coordinator.startPrepared(
            jobID: harness.jobID,
            configuration: harness.configuration
        )

        let preflightRequests = await harness.transcoder
            .observedPreflightRequests()
        let preflightRecipe = try #require(preflightRequests.first?.recipe)
        #expect(preflightRequests.count == 1)
        #expect(preflightRecipe == harness.configuration.recipe)
        #expect(
            preflightRecipe.audioPolicy == .aac(
                try AudioBitRate(bitsPerSecond: 128_000)
            )
        )
    }

    @Test("Coordinator runs probe through atomic commit in order")
    func successfulWorkflow() async throws {
        let harness = try await WorkflowHarness.make()

        let completed = try await harness.coordinator.process(
            jobID: harness.jobID,
            configuration: harness.configuration
        )

        guard case .completed(let result) = completed.state else {
            Issue.record("Expected completed state, got \(completed.state)")
            return
        }
        #expect(result.outputURL == harness.urls.final)
        #expect(result.outputByteCount == WorkflowHarness.outputByteCount)
        #expect(result.elapsed >= .zero)
        #expect(
            harness.events.snapshot() == [
                "scope.begin",
                "probe.input",
                "plan",
                "metadata.input",
                "metadata.directory",
                "metadata.temporary.preflight",
                "metadata.final",
                "transcode.preflight",
                "reserve.temporary",
                "transcode.start",
                "transcode.progress",
                "metadata.temporary.validation",
                "probe.temporary",
                "metadata.temporary.validation",
                "validate",
                "commit",
                "scope.end",
            ]
        )

        let requests = await harness.transcoder.observedTranscodeRequests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.inputURL == harness.urls.input)
        #expect(request.temporaryOutputURL == harness.urls.temporary)
        #expect(request.inputURL != harness.urls.final)
        #expect(request.temporaryOutputURL != harness.urls.final)
        #expect(await harness.fileAccess.committedPlans().map(\.finalURL) == [harness.urls.final])
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)

        let stored = try #require(await harness.coordinator.job(id: harness.jobID))
        #expect(stored == completed)
    }

    @Test("Equal or larger validated output returns NoBenefit without commit")
    func noBenefitDoesNotPublish() async throws {
        for candidateByteCount in [
            WorkflowHarness.sourceByteCount,
            WorkflowHarness.sourceByteCount * 2,
        ] {
            let harness = try await WorkflowHarness.make(
                options: .init(outputByteCount: candidateByteCount)
            )

            let finished = try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )

            guard case .noBenefit(let result) = finished.state else {
                Issue.record(
                    "Expected noBenefit for candidate size \(candidateByteCount), got \(finished.state)"
                )
                continue
            }
            #expect(result.sourceByteCount == WorkflowHarness.sourceByteCount)
            #expect(result.candidateByteCount == candidateByteCount)
            #expect(result.elapsed >= .zero)
            #expect(await harness.fileAccess.committedPlans().isEmpty)
            try await expectOnlyExactCleanup(harness)

            let events = harness.events.snapshot()
            let validationIndex = try #require(
                events.firstIndex(of: "validate")
            )
            let cleanupIndex = try #require(
                events.firstIndex(of: "cleanup")
            )
            #expect(validationIndex < cleanupIndex)
            #expect(!events.contains("commit"))
        }
    }

    @Test("NoBenefit cleanup failure is one validate file-system failure")
    func noBenefitCleanupFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(
                outputByteCount: WorkflowHarness.sourceByteCount,
                cleanupFailure: .cleanup
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .validate)
        #expect(failure.reason == .fileSystem)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .validate
        )
        #expect(await harness.fileAccess.committedPlans().isEmpty)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Preparation stops in ready and prepared start does not re-probe")
    func preparedWorkflow() async throws {
        let harness = try await WorkflowHarness.make()

        let ready = try await harness.coordinator.prepare(
            jobID: harness.jobID
        )

        #expect(ready.state == .ready)
        #expect(ready.mediaInfo != nil)
        #expect(ready.configuration == nil)
        #expect(
            harness.events.snapshot() == [
                "scope.begin",
                "probe.input",
                "scope.end",
            ]
        )

        let completed = try await harness.coordinator.startPrepared(
            jobID: harness.jobID,
            configuration: harness.configuration
        )

        guard case .completed = completed.state else {
            Issue.record("Expected completed state, got \(completed.state)")
            return
        }
        let events = harness.events.snapshot()
        #expect(events.filter { $0 == "probe.input" }.count == 1)
        #expect(events.filter { $0 == "scope.begin" }.count == 2)
        #expect(events.filter { $0 == "scope.end" }.count == 2)
        #expect(events.contains("transcode.start"))
        #expect(events.contains("probe.temporary"))
        #expect(events.contains("commit"))
    }

    @Test("A cancelled prepared job accepts a fresh configuration on retry")
    func cancelledPreparedRetry() async throws {
        let harness = try await WorkflowHarness.make()
        let ready = try await harness.coordinator.prepare(
            jobID: harness.jobID
        )
        #expect(ready.configuration == nil)

        await harness.coordinator.cancel(jobID: harness.jobID)
        let cancelled = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.mediaInfo != nil)
        #expect(cancelled.configuration == nil)

        let completed = try await harness.coordinator.retry(
            jobID: harness.jobID,
            configuration: harness.configuration
        )

        guard case .completed = completed.state else {
            Issue.record("Expected completed state, got \(completed.state)")
            return
        }
        let events = harness.events.snapshot()
        #expect(events.filter { $0 == "probe.input" }.count == 1)
        #expect(events.filter { $0 == "transcode.start" }.count == 1)
    }

    @Test("Encode retry reuses prepared media and the same job identity")
    func preparedEncodeRetry() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(transcodeFailure: .encode)
        )
        _ = try await harness.coordinator.prepare(jobID: harness.jobID)

        do {
            _ = try await harness.coordinator.startPrepared(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
            Issue.record("Expected first encode failure")
        } catch let failure as TranscodeFailure {
            #expect(failure.stage == .encode)
        }

        do {
            _ = try await harness.coordinator.retry(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
            Issue.record("Expected retry encode failure")
        } catch let failure as TranscodeFailure {
            #expect(failure.stage == .encode)
        }

        let stored = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        guard case .failed(let failure) = stored.state else {
            Issue.record("Expected failed state, got \(stored.state)")
            return
        }
        #expect(failure.retryTarget == .ready)
        let events = harness.events.snapshot()
        #expect(events.filter { $0 == "probe.input" }.count == 1)
        #expect(events.filter { $0 == "transcode.start" }.count == 2)
        #expect(await harness.fileAccess.cleanedPlans().count == 2)
    }

    @Test("Probe retry repeats preparation without starting encode")
    func probeRetry() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(inputProbeFailure: .probe)
        )

        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    _ = try await harness.coordinator.prepare(
                        jobID: harness.jobID
                    )
                } else {
                    _ = try await harness.coordinator.retry(
                        jobID: harness.jobID,
                        configuration: harness.configuration
                    )
                }
                Issue.record("Expected probe failure")
            } catch let failure as TranscodeFailure {
                #expect(failure.stage == .probe)
            }
        }

        let events = harness.events.snapshot()
        #expect(events.filter { $0 == "probe.input" }.count == 2)
        #expect(!events.contains("transcode.start"))
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
    }

    @Test("Preflight failures never clean a path the workflow did not create")
    func preflightFailures() async throws {
        let cases: [WorkflowHarness.Options] = [
            .init(finalOutputExists: true),
            .init(preflightFailure: .preflight),
        ]

        for options in cases {
            let harness = try await WorkflowHarness.make(options: options)
            let failure = try await requireFailure(harness)

            #expect(failure.stage == .preflight)
            try await expectFailedState(
                coordinator: harness.coordinator,
                jobID: harness.jobID,
                stage: .preflight
            )
            #expect(await harness.fileAccess.cleanedPlans().isEmpty)
            #expect(await harness.fileAccess.committedPlans().isEmpty)
            #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
        }
    }

    @Test("An invalid FFprobe source is an input-unavailable failure")
    func invalidProbeSourceFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(
                inputProbeClientFailure: .invalidSourceURL
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .probe)
        #expect(failure.reason == .inputUnavailable)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .probe
        )
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
    }

    @Test("A missing bundled FFprobe is a probe service failure")
    func unavailableProbeExecutableFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(
                inputProbeClientFailure: .bundledExecutableUnavailable
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .probe)
        #expect(failure.reason == .serviceUnavailable)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .probe
        )
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
    }

    @Test("A process-runner launch error is a probe service failure")
    func probeRunnerFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(
                inputProbeRunnerFailure: .launchFailed(
                    ProcessExecutionID()
                )
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .probe)
        #expect(failure.reason == .serviceUnavailable)
        #expect(failure.technicalCode == .processLaunchFailed)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .probe
        )
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
    }

    @Test("Encode failure cleans temp and becomes an encode failure")
    func encodeFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(transcodeFailure: .encode)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .encode)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .encode
        )
        try await expectOnlyExactCleanup(harness)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("Output validation failure is classified after the second probe")
    func outputValidationFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(validationFailure: .validate)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .validate)
        #expect(failure.reason == .invalidMedia)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .validate
        )
        try await expectOnlyExactCleanup(harness)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
        let events = harness.events.snapshot()
        let reprobeIndex = try #require(events.firstIndex(of: "probe.temporary"))
        let validationIndex = try #require(events.firstIndex(of: "validate"))
        let cleanupIndex = try #require(events.firstIndex(of: "cleanup"))
        #expect(reprobeIndex < validationIndex)
        #expect(validationIndex < cleanupIndex)
    }

    @Test("Commit failure is classified and leaves no job temp")
    func commitFailure() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(commitFailure: .commit)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .commit)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .commit
        )
        try await expectOnlyExactCleanup(harness)
        #expect(await harness.fileAccess.committedPlans().count == 1)
    }

    @Test("Cancellation wins a later service error and cleans temp")
    func cancellationWinsServiceError() async throws {
        let started = WorkflowGate()
        let release = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                transcodeFailure: .encode,
                transcodeStarted: started,
                transcodeRelease: release
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await started.waitUntilOpen()
        await harness.coordinator.cancel(jobID: harness.jobID)

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: the fake's later encode error must not escape.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let stored = try #require(await harness.coordinator.job(id: harness.jobID))
        #expect(stored.state == .cancelled)
        try await expectOnlyExactCleanup(harness)
        #expect(await harness.transcoder.cancelCount() >= 1)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("Cancellation before service registration cleans its reservation")
    func cancellationBeforeTranscoderRegistration() async throws {
        let registrationStarted = WorkflowGate()
        let registrationRelease = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                transcodeRegistrationStarted: registrationStarted,
                transcodeRegistrationRelease: registrationRelease
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await registrationStarted.waitUntilOpen()
        let running = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(running.state == .running(progress: nil))

        await harness.coordinator.cancel(jobID: harness.jobID)

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let stored = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(stored.state == .cancelled)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
        #expect(await harness.transcoder.cancelCount() >= 1)
        try await expectOnlyExactCleanup(harness)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("A pre-existing planned temporary is preserved")
    func preexistingTemporaryIsNeverCleaned() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(temporaryOutputExists: true)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .preflight)
        #expect(failure.reason == .outputConflict)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("Cancellation during probe wins a later probe failure")
    func cancellationWinsProbeFailure() async throws {
        let started = WorkflowGate()
        let release = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                inputProbeFailure: .probe,
                inputProbeStarted: started,
                inputProbeRelease: release
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await started.waitUntilOpen()
        await harness.coordinator.cancel(jobID: harness.jobID)
        await release.open()

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: the later probe failure must not escape.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let stored = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(stored.state == .cancelled)
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
    }

    @Test("Cancellation during preflight wins a later preflight failure")
    func cancellationWinsPreflightFailure() async throws {
        let started = WorkflowGate()
        let release = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                preflightFailure: .preflight,
                preflightStarted: started,
                preflightRelease: release
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await started.waitUntilOpen()
        await harness.coordinator.cancel(jobID: harness.jobID)
        await release.open()

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected: the later preflight failure must not escape.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let stored = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(stored.state == .cancelled)
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("A second workflow for the same job is rejected")
    func duplicateWorkflow() async throws {
        let started = WorkflowGate()
        let release = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                transcodeStarted: started,
                transcodeRelease: release
            )
        )
        let first = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }
        try await started.waitUntilOpen()

        do {
            _ = try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
            Issue.record("Expected duplicate workflow rejection")
        } catch let error as CompressionCoordinatorError {
            #expect(error == .workflowAlreadyRunning(harness.jobID))
        }

        await harness.coordinator.cancel(jobID: harness.jobID)
        do {
            _ = try await first.value
            Issue.record("Expected the first workflow to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        #expect(await harness.transcoder.observedTranscodeRequests().count == 1)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Cancellation during transcoder preflight prevents encode")
    func cancellationDuringPreflight() async throws {
        let started = WorkflowGate()
        let release = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                preflightStarted: started,
                preflightRelease: release
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await started.waitUntilOpen()
        await harness.coordinator.cancel(jobID: harness.jobID)
        await release.open()

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let stored = try #require(await harness.coordinator.job(id: harness.jobID))
        #expect(stored.state == .cancelled)
        #expect(await harness.transcoder.observedTranscodeRequests().isEmpty)
        #expect(await harness.fileAccess.cleanedPlans().isEmpty)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
    }

    @Test("FFmpeg process failure preserves exit status and bounded diagnostics")
    func ffmpegProcessFailureMapping() async throws {
        let diagnosticText = "bounded ffmpeg diagnostic\n"
        let diagnosticLimit = 64
        let diagnostic = try BoundedData(
            data: Data(diagnosticText.utf8),
            byteLimit: diagnosticLimit,
            wasTruncated: true
        )
        let serviceFailure = FFmpegTranscodingServiceError.processFailed(
            termination: ProcessTerminationStatus(
                status: 37,
                reason: .exit
            ),
            diagnosticTail: diagnostic
        )
        let harness = try await WorkflowHarness.make(
            options: .init(transcodingServiceFailure: serviceFailure)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .encode)
        #expect(failure.reason == .processFailed(exitCode: 37))
        #expect(failure.diagnosticTail?.text == diagnosticText)
        #expect(failure.diagnosticTail?.utf8ByteLimit == diagnosticLimit)
        #expect(failure.diagnosticTail?.wasTruncated == true)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .encode
        )
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Progress protocol failures expose a path-free technical code")
    func progressProtocolFailureMapping() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(
                transcodingServiceFailure: .progressParsing(
                    .invalidValue(key: "speed")
                )
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .encode)
        #expect(failure.reason == .serviceUnavailable)
        #expect(failure.diagnosticTail == nil)
        #expect(failure.technicalCode == .transcoderProgressProtocolError)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("A bounded no-space diagnostic becomes actionable storage failure")
    func noSpaceProcessFailureMapping() async throws {
        let diagnostic = try BoundedData(
            data: Data("muxer: No space left on device\n".utf8),
            byteLimit: 128,
            wasTruncated: false
        )
        let harness = try await WorkflowHarness.make(
            options: .init(
                transcodingServiceFailure: .processFailed(
                    termination: ProcessTerminationStatus(
                        status: 1,
                        reason: .exit
                    ),
                    diagnosticTail: diagnostic
                )
            )
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .encode)
        #expect(failure.reason == .insufficientStorage)
        #expect(failure.diagnosticTail?.text.contains("No space") == true)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Cancellation during validation cleans up without publishing")
    func cancellationDuringValidation() async throws {
        let validationStarted = WorkflowGate()
        let validationRelease = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                validationProbeStarted: validationStarted,
                validationProbeRelease: validationRelease
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await validationStarted.waitUntilOpen()
        let finishing = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(finishing.state == .finishing(.validating))
        await harness.coordinator.cancel(jobID: harness.jobID)
        await validationRelease.open()

        do {
            _ = try await operation.value
            Issue.record("Expected validation cancellation")
        } catch is CancellationError {
            // Expected after the cancellable validation operation unwinds.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let cancelled = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(cancelled.state == .cancelled)
        #expect(await harness.transcoder.cancelCount() == 0)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Cancellation before final publication cleans up without committing")
    func cancellationDuringCommit() async throws {
        let commitStarted = WorkflowGate()
        let commitRelease = WorkflowGate()
        let harness = try await WorkflowHarness.make(
            options: .init(
                commitStarted: commitStarted,
                commitRelease: commitRelease
            )
        )
        let operation = Task {
            try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
        }

        try await commitStarted.waitUntilOpen()
        let finishing = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(finishing.state == .finishing(.committing))
        await harness.coordinator.cancel(jobID: harness.jobID)
        await commitRelease.open()

        do {
            _ = try await operation.value
            Issue.record("Expected commit cancellation")
        } catch is CancellationError {
            // Expected before the exclusive publication operation completes.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        let cancelled = try #require(
            await harness.coordinator.job(id: harness.jobID)
        )
        #expect(cancelled.state == .cancelled)
        #expect(await harness.fileAccess.committedPlans().isEmpty)
        try await expectOnlyExactCleanup(harness)
    }

    @Test("Cleanup failures after encode and cancel become file-system failures")
    func cleanupFailureIsNotSuppressed() async throws {
        let encodeHarness = try await WorkflowHarness.make(
            options: .init(
                transcodeFailure: .encode,
                cleanupFailure: .cleanup
            )
        )
        let encodeFailure = try await requireFailure(encodeHarness)

        #expect(encodeFailure.stage == .encode)
        #expect(encodeFailure.reason == .fileSystem)
        try await expectFailedState(
            coordinator: encodeHarness.coordinator,
            jobID: encodeHarness.jobID,
            stage: .encode
        )
        try await expectOnlyExactCleanup(encodeHarness)

        let started = WorkflowGate()
        let release = WorkflowGate()
        let cancellationHarness = try await WorkflowHarness.make(
            options: .init(
                transcodeFailure: .encode,
                cleanupFailure: .cleanup,
                transcodeStarted: started,
                transcodeRelease: release
            )
        )
        let operation = Task {
            try await cancellationHarness.coordinator.process(
                jobID: cancellationHarness.jobID,
                configuration: cancellationHarness.configuration
            )
        }
        try await started.waitUntilOpen()
        await cancellationHarness.coordinator.cancel(
            jobID: cancellationHarness.jobID
        )

        do {
            _ = try await operation.value
            Issue.record("Expected cleanup failure")
        } catch let failure as TranscodeFailure {
            #expect(failure.stage == .encode)
            #expect(failure.reason == .fileSystem)
        } catch {
            Issue.record("Expected TranscodeFailure, got \(error)")
        }
        try await expectFailedState(
            coordinator: cancellationHarness.coordinator,
            jobID: cancellationHarness.jobID,
            stage: .encode
        )
        try await expectOnlyExactCleanup(cancellationHarness)
    }

    @Test("A changed temporary file fails validation before commit")
    func temporaryMetadataChangesDuringValidation() async throws {
        let harness = try await WorkflowHarness.make(
            options: .init(temporaryMetadataChangesAfterProbe: true)
        )

        let failure = try await requireFailure(harness)

        #expect(failure.stage == .validate)
        #expect(failure.reason == .fileSystem)
        try await expectFailedState(
            coordinator: harness.coordinator,
            jobID: harness.jobID,
            stage: .validate
        )
        #expect(await harness.fileAccess.committedPlans().isEmpty)
        try await expectOnlyExactCleanup(harness)
        let events = harness.events.snapshot()
        let probeIndex = try #require(events.firstIndex(of: "probe.temporary"))
        let changedIndex = try #require(
            events.firstIndex(of: "metadata.temporary.changed")
        )
        let cleanupIndex = try #require(events.firstIndex(of: "cleanup"))
        #expect(probeIndex < changedIndex)
        #expect(changedIndex < cleanupIndex)
        #expect(!events.contains("validate"))
        #expect(!events.contains("commit"))
    }

    private func requireFailure(
        _ harness: WorkflowHarness
    ) async throws -> TranscodeFailure {
        do {
            _ = try await harness.coordinator.process(
                jobID: harness.jobID,
                configuration: harness.configuration
            )
            Issue.record("Expected workflow failure")
            throw WorkflowFakeError.expectedFailure
        } catch let failure as TranscodeFailure {
            return failure
        }
    }

    private func expectFailedState(
        coordinator: CompressionCoordinator,
        jobID: CompressionJob.ID,
        stage: FailureStage
    ) async throws {
        let stored = try #require(await coordinator.job(id: jobID))
        guard case .failed(let failure) = stored.state else {
            Issue.record("Expected failed state, got \(stored.state)")
            return
        }
        #expect(failure.stage == stage)
    }

    private func expectOnlyExactCleanup(
        _ harness: WorkflowHarness
    ) async throws {
        let cleanups = await harness.fileAccess.cleanedPlans()
        let cleanup = try #require(cleanups.first)
        #expect(cleanups.count == 1)
        #expect(cleanup.jobID == harness.jobID)
        #expect(cleanup.inputURL == harness.urls.input)
        #expect(cleanup.temporaryURL == harness.urls.temporary)
        #expect(cleanup.finalURL == harness.urls.final)
    }
}

private nonisolated struct WorkflowHarness: Sendable {
    static let sourceByteCount: Int64 = 1_024
    static let outputByteCount: Int64 = 777

    nonisolated struct Options: Sendable {
        var outputByteCount = WorkflowHarness.outputByteCount
        var finalOutputExists = false
        var temporaryOutputExists = false
        var inputProbeFailure: WorkflowFakeError?
        var inputProbeClientFailure: FFprobeClientError?
        var inputProbeRunnerFailure: ProcessRunnerError?
        var preflightFailure: WorkflowFakeError?
        var transcodeFailure: WorkflowFakeError?
        var transcodingServiceFailure: FFmpegTranscodingServiceError?
        var validationFailure: WorkflowFakeError?
        var commitFailure: WorkflowFakeError?
        var cleanupFailure: WorkflowFakeError?
        var temporaryMetadataChangesAfterProbe = false
        var inputProbeStarted: WorkflowGate?
        var inputProbeRelease: WorkflowGate?
        var preflightStarted: WorkflowGate?
        var preflightRelease: WorkflowGate?
        var transcodeRegistrationStarted: WorkflowGate?
        var transcodeRegistrationRelease: WorkflowGate?
        var transcodeStarted: WorkflowGate?
        var transcodeRelease: WorkflowGate?
        var validationProbeStarted: WorkflowGate?
        var validationProbeRelease: WorkflowGate?
        var commitStarted: WorkflowGate?
        var commitRelease: WorkflowGate?
    }

    let jobID: CompressionJob.ID
    let urls: WorkflowURLs
    let configuration: JobConfiguration
    let coordinator: CompressionCoordinator
    let transcoder: WorkflowTranscoder
    let fileAccess: WorkflowFileAccess
    let events: WorkflowEventLog

    static func make(
        options: Options = Options()
    ) async throws -> WorkflowHarness {
        let jobID = UUID()
        let root = URL(
            fileURLWithPath: "/tmp/ResizerWorkflowTests/\(jobID.uuidString)",
            isDirectory: true
        )
        let outputDirectory = root.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        let urls = WorkflowURLs(
            input: root.appendingPathComponent("source.mov"),
            outputDirectory: outputDirectory,
            temporary: outputDirectory.appendingPathComponent(
                "source-compressed.\(jobID.uuidString.lowercased()).partial.mp4"
            ),
            final: outputDirectory.appendingPathComponent(
                "source-compressed.mp4"
            )
        )
        let source = try TestFixtures.mediaInfo()
        let encoded = try TestFixtures.mediaInfo()
        let configuration = JobConfiguration(
            recipe: try AutomaticCompressionPolicy().recipe(
                for: source,
                settings: .quick(audio: .keep)
            ),
            outputPolicy: try OutputPolicy(
                directoryURL: outputDirectory
            )
        )
        let events = WorkflowEventLog()
        let prober = WorkflowProber(
            urls: urls,
            source: source,
            encoded: encoded,
            inputFailure: options.inputProbeFailure,
            inputClientFailure: options.inputProbeClientFailure,
            inputRunnerFailure: options.inputProbeRunnerFailure,
            inputStarted: options.inputProbeStarted,
            inputRelease: options.inputProbeRelease,
            validationStarted: options.validationProbeStarted,
            validationRelease: options.validationProbeRelease,
            events: events
        )
        let planner = WorkflowPlanner(urls: urls, events: events)
        let transcoder = WorkflowTranscoder(
            outputByteCount: options.outputByteCount,
            progress: try TestFixtures.progress(),
            preflightFailure: options.preflightFailure,
            transcodeFailure: options.transcodeFailure,
            serviceFailure: options.transcodingServiceFailure,
            preflightStarted: options.preflightStarted,
            preflightRelease: options.preflightRelease,
            registrationStarted: options.transcodeRegistrationStarted,
            registrationRelease: options.transcodeRegistrationRelease,
            started: options.transcodeStarted,
            release: options.transcodeRelease,
            events: events
        )
        let fileAccess = WorkflowFileAccess(
            urls: urls,
            outputByteCount: options.outputByteCount,
            finalOutputExists: options.finalOutputExists,
            temporaryOutputExists: options.temporaryOutputExists,
            commitFailure: options.commitFailure,
            cleanupFailure: options.cleanupFailure,
            commitStarted: options.commitStarted,
            commitRelease: options.commitRelease,
            temporaryMetadataChangesAfterProbe:
                options.temporaryMetadataChangesAfterProbe,
            events: events
        )
        let validator = WorkflowValidator(
            expectedOutput: encoded,
            expectedSource: source,
            expectedRecipe: configuration.recipe,
            failure: options.validationFailure,
            events: events
        )
        let coordinator = CompressionCoordinator(
            dependencies: CompressionCoordinatorDependencies(
                mediaProber: prober,
                transcoder: transcoder,
                outputPlanner: planner,
                fileAccess: fileAccess,
                outputValidator: validator
            )
        )
        _ = try await coordinator.createJob(
            inputURL: urls.input,
            id: jobID
        )
        return WorkflowHarness(
            jobID: jobID,
            urls: urls,
            configuration: configuration,
            coordinator: coordinator,
            transcoder: transcoder,
            fileAccess: fileAccess,
            events: events
        )
    }
}

private nonisolated struct WorkflowURLs: Sendable, Equatable {
    let input: URL
    let outputDirectory: URL
    let temporary: URL
    let final: URL
}

private nonisolated enum WorkflowFakeError: Error, Sendable, Equatable {
    case expectedFailure
    case unexpectedRequest
    case probe
    case preflight
    case encode
    case validate
    case commit
    case cleanup
}

private nonisolated final class WorkflowEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor WorkflowGate {
    private var isOpen = false

    func open() {
        isOpen = true
    }

    func wait() async throws {
        while !isOpen {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilOpen() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !isOpen {
            guard clock.now < deadline else {
                throw WorkflowFakeError.unexpectedRequest
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor WorkflowProber: MediaProbing {
    private let urls: WorkflowURLs
    private let source: MediaInfo
    private let encoded: MediaInfo
    private let inputFailure: WorkflowFakeError?
    private let inputClientFailure: FFprobeClientError?
    private let inputRunnerFailure: ProcessRunnerError?
    private let inputStarted: WorkflowGate?
    private let inputRelease: WorkflowGate?
    private let validationStarted: WorkflowGate?
    private let validationRelease: WorkflowGate?
    private let events: WorkflowEventLog

    init(
        urls: WorkflowURLs,
        source: MediaInfo,
        encoded: MediaInfo,
        inputFailure: WorkflowFakeError?,
        inputClientFailure: FFprobeClientError?,
        inputRunnerFailure: ProcessRunnerError?,
        inputStarted: WorkflowGate?,
        inputRelease: WorkflowGate?,
        validationStarted: WorkflowGate?,
        validationRelease: WorkflowGate?,
        events: WorkflowEventLog
    ) {
        self.urls = urls
        self.source = source
        self.encoded = encoded
        self.inputFailure = inputFailure
        self.inputClientFailure = inputClientFailure
        self.inputRunnerFailure = inputRunnerFailure
        self.inputStarted = inputStarted
        self.inputRelease = inputRelease
        self.validationStarted = validationStarted
        self.validationRelease = validationRelease
        self.events = events
    }

    func probe(_ sourceURL: URL) async throws -> MediaInfo {
        if sourceURL == urls.input {
            events.append("probe.input")
            await inputStarted?.open()
            try await inputRelease?.wait()
            if let inputClientFailure {
                throw inputClientFailure
            }
            if let inputRunnerFailure {
                throw inputRunnerFailure
            }
            if let inputFailure {
                throw inputFailure
            }
            return source
        }
        if sourceURL == urls.temporary {
            events.append("probe.temporary")
            await validationStarted?.open()
            try await validationRelease?.wait()
            return encoded
        }
        throw WorkflowFakeError.unexpectedRequest
    }
}

private actor WorkflowPlanner: OutputPlanning {
    private let urls: WorkflowURLs
    private let events: WorkflowEventLog

    init(urls: WorkflowURLs, events: WorkflowEventLog) {
        self.urls = urls
        self.events = events
    }

    func planOutput(
        for request: OutputPlanningRequest
    ) async throws -> OutputPlan {
        events.append("plan")
        guard request.inputURL == urls.input,
              request.policy.directoryURL == urls.outputDirectory else {
            throw WorkflowFakeError.unexpectedRequest
        }
        return try OutputPlan(
            request: request,
            temporaryURL: urls.temporary,
            finalURL: urls.final
        )
    }
}

private actor WorkflowTranscoder: Transcoding {
    private let outputByteCount: Int64
    private let progress: TranscodeProgress
    private let preflightFailure: WorkflowFakeError?
    private let transcodeFailure: WorkflowFakeError?
    private let serviceFailure: FFmpegTranscodingServiceError?
    private let preflightStarted: WorkflowGate?
    private let preflightRelease: WorkflowGate?
    private let registrationStarted: WorkflowGate?
    private let registrationRelease: WorkflowGate?
    private let started: WorkflowGate?
    private let release: WorkflowGate?
    private let events: WorkflowEventLog
    private var capabilityRecipes: [CompressionRecipe] = []
    private var preflightRequests: [TranscodeRequest] = []
    private var transcodeRequests: [TranscodeRequest] = []
    private var cancellations = 0

    init(
        outputByteCount: Int64,
        progress: TranscodeProgress,
        preflightFailure: WorkflowFakeError?,
        transcodeFailure: WorkflowFakeError?,
        serviceFailure: FFmpegTranscodingServiceError?,
        preflightStarted: WorkflowGate?,
        preflightRelease: WorkflowGate?,
        registrationStarted: WorkflowGate?,
        registrationRelease: WorkflowGate?,
        started: WorkflowGate?,
        release: WorkflowGate?,
        events: WorkflowEventLog
    ) {
        self.outputByteCount = outputByteCount
        self.progress = progress
        self.preflightFailure = preflightFailure
        self.transcodeFailure = transcodeFailure
        self.serviceFailure = serviceFailure
        self.preflightStarted = preflightStarted
        self.preflightRelease = preflightRelease
        self.registrationStarted = registrationStarted
        self.registrationRelease = registrationRelease
        self.started = started
        self.release = release
        self.events = events
    }

    func validateCapabilities(
        for mediaInfo: MediaInfo,
        recipe: CompressionRecipe
    ) async throws {
        _ = mediaInfo
        capabilityRecipes.append(recipe)
    }

    func preflight(_ request: TranscodeRequest) async throws {
        preflightRequests.append(request)
        events.append("transcode.preflight")
        await preflightStarted?.open()
        try await preflightRelease?.wait()
        if let preflightFailure {
            throw preflightFailure
        }
    }

    func transcode(
        _ request: TranscodeRequest,
        reservation: TemporaryOutputReservation,
        onProgress: @escaping @Sendable (TranscodeProgress) async -> Void
    ) async throws -> TranscodeResult {
        await registrationStarted?.open()
        try await registrationRelease?.wait()
        guard reservation.jobID == request.jobID,
              reservation.temporaryURL
                == request.temporaryOutputURL.standardizedFileURL,
              reservation.metadata.identity
                == FileIdentity(device: 42, inode: 7_777) else {
            throw WorkflowFakeError.unexpectedRequest
        }
        transcodeRequests.append(request)
        events.append("transcode.start")
        events.append("transcode.progress")
        await onProgress(progress)
        await started?.open()
        try await release?.wait()
        if let transcodeFailure {
            throw transcodeFailure
        }
        if let serviceFailure {
            throw serviceFailure
        }
        return try TranscodeResult(
            byteCount: outputByteCount,
            temporaryMetadata: FileMetadata(
                byteCount: outputByteCount,
                isDirectory: false,
                identity: FileIdentity(device: 42, inode: 7_777)
            )
        )
    }

    func cancel(jobID: CompressionJob.ID) async {
        _ = jobID
        cancellations += 1
        events.append("transcode.cancel")
        await release?.open()
    }

    func observedTranscodeRequests() -> [TranscodeRequest] {
        transcodeRequests
    }

    func observedCapabilityRecipes() -> [CompressionRecipe] {
        capabilityRecipes
    }

    func observedPreflightRequests() -> [TranscodeRequest] {
        preflightRequests
    }

    func cancelCount() -> Int {
        cancellations
    }
}

private actor WorkflowFileAccess: FileAccessing {
    private static let temporaryIdentity = FileIdentity(
        device: 42,
        inode: 7_777
    )

    private let urls: WorkflowURLs
    private let outputByteCount: Int64
    private let finalOutputExists: Bool
    private let temporaryOutputExists: Bool
    private let commitFailure: WorkflowFakeError?
    private let cleanupFailure: WorkflowFakeError?
    private let commitStarted: WorkflowGate?
    private let commitRelease: WorkflowGate?
    private let temporaryMetadataChangesAfterProbe: Bool
    private let events: WorkflowEventLog
    private var temporaryIsReserved = false
    private var reservationMetadataCalls = 0
    private var commits: [OutputPlan] = []
    private var cleanups: [OutputPlan] = []

    init(
        urls: WorkflowURLs,
        outputByteCount: Int64,
        finalOutputExists: Bool,
        temporaryOutputExists: Bool,
        commitFailure: WorkflowFakeError?,
        cleanupFailure: WorkflowFakeError?,
        commitStarted: WorkflowGate?,
        commitRelease: WorkflowGate?,
        temporaryMetadataChangesAfterProbe: Bool,
        events: WorkflowEventLog
    ) {
        self.urls = urls
        self.outputByteCount = outputByteCount
        self.finalOutputExists = finalOutputExists
        self.temporaryOutputExists = temporaryOutputExists
        self.commitFailure = commitFailure
        self.cleanupFailure = cleanupFailure
        self.commitStarted = commitStarted
        self.commitRelease = commitRelease
        self.temporaryMetadataChangesAfterProbe =
            temporaryMetadataChangesAfterProbe
        self.events = events
    }

    func withSecurityScopedAccess<Result: Sendable>(
        to selectedURLs: [URL],
        perform operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        guard selectedURLs == [urls.input]
            || selectedURLs == [urls.input, urls.outputDirectory] else {
            throw WorkflowFakeError.unexpectedRequest
        }
        events.append("scope.begin")
        defer { events.append("scope.end") }
        return try await operation()
    }

    func metadata(at url: URL) async throws -> FileMetadata? {
        if url == urls.input {
            events.append("metadata.input")
            return FileMetadata(
                byteCount: WorkflowHarness.sourceByteCount,
                isDirectory: false
            )
        }
        if url == urls.outputDirectory {
            events.append("metadata.directory")
            return FileMetadata(byteCount: 0, isDirectory: true)
        }
        if url == urls.temporary {
            if !temporaryIsReserved {
                events.append("metadata.temporary.preflight")
                return temporaryOutputExists
                    ? FileMetadata(
                        byteCount: outputByteCount,
                        isDirectory: false,
                        identity: Self.temporaryIdentity
                    )
                    : nil
            }
            reservationMetadataCalls += 1
            if reservationMetadataCalls >= 2,
               temporaryMetadataChangesAfterProbe {
                events.append("metadata.temporary.changed")
                return FileMetadata(
                    byteCount: outputByteCount,
                    isDirectory: false,
                    identity: FileIdentity(device: 42, inode: 7_778)
                )
            }
            events.append("metadata.temporary.validation")
            return FileMetadata(
                byteCount: outputByteCount,
                isDirectory: false,
                identity: Self.temporaryIdentity
            )
        }
        if url == urls.final {
            events.append("metadata.final")
            return finalOutputExists
                ? FileMetadata(byteCount: 10, isDirectory: false)
                : nil
        }
        throw WorkflowFakeError.unexpectedRequest
    }

    func reserveTemporaryOutput(
        _ plan: OutputPlan
    ) async throws -> TemporaryOutputReservation {
        guard plan.temporaryURL == urls.temporary else {
            throw WorkflowFakeError.unexpectedRequest
        }
        temporaryIsReserved = true
        reservationMetadataCalls = 0
        events.append("reserve.temporary")
        return try TemporaryOutputReservation(
            plan: plan,
            metadata: FileMetadata(
                byteCount: 0,
                isDirectory: false,
                identity: Self.temporaryIdentity
            )
        )
    }

    func commitWithoutReplacing(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata
    ) async throws {
        guard reservation.jobID == plan.jobID,
            reservation.temporaryURL
                == plan.temporaryURL.standardizedFileURL,
            expectedTemporaryMetadata.identity
            == Self.temporaryIdentity,
            expectedTemporaryMetadata.byteCount == outputByteCount,
            !expectedTemporaryMetadata.isDirectory else {
            throw WorkflowFakeError.unexpectedRequest
        }
        await commitStarted?.open()
        try await commitRelease?.wait()
        commits.append(plan)
        events.append("commit")
        if let commitFailure {
            throw commitFailure
        }
    }

    func cleanupTemporaryOutput(
        _ plan: OutputPlan,
        reservation: TemporaryOutputReservation,
        expectedTemporaryMetadata: FileMetadata?
    ) async throws {
        guard reservation.jobID == plan.jobID,
            reservation.temporaryURL
                == plan.temporaryURL.standardizedFileURL else {
            throw WorkflowFakeError.unexpectedRequest
        }
        if let expectedTemporaryMetadata {
            guard expectedTemporaryMetadata.identity
                    == Self.temporaryIdentity,
                  !expectedTemporaryMetadata.isDirectory else {
                throw WorkflowFakeError.unexpectedRequest
            }
        }
        cleanups.append(plan)
        events.append("cleanup")
        if temporaryMetadataChangesAfterProbe {
            throw WorkflowFakeError.cleanup
        }
        if let cleanupFailure {
            throw cleanupFailure
        }
        temporaryIsReserved = false
        reservationMetadataCalls = 0
    }

    func committedPlans() -> [OutputPlan] {
        commits
    }

    func cleanedPlans() -> [OutputPlan] {
        cleanups
    }
}

private nonisolated struct WorkflowValidator:
    TranscodeOutputValidating,
    Sendable
{
    let expectedOutput: MediaInfo
    let expectedSource: MediaInfo
    let expectedRecipe: CompressionRecipe
    let failure: WorkflowFakeError?
    let events: WorkflowEventLog

    func validate(
        output: MediaInfo,
        source: MediaInfo,
        recipe: CompressionRecipe
    ) throws {
        events.append("validate")
        guard output == expectedOutput,
              source == expectedSource,
              recipe == expectedRecipe else {
            throw WorkflowFakeError.unexpectedRequest
        }
        if let failure {
            throw failure
        }
    }
}
