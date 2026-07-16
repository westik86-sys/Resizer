import Foundation
import Testing
@testable import Resizer

@Suite("Compression queue feature model", .serialized)
@MainActor
struct CompressionFeatureModelTests {
    @Test("Batch import keeps supported files in selection order")
    func batchImportIsAdditiveAndOrdered() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()

        await model.importVideos([
            URL(fileURLWithPath: "/tmp/one.mp4"),
            URL(fileURLWithPath: "/tmp/not-video.avi"),
            URL(fileURLWithPath: "/tmp/two.MOV"),
        ])

        #expect(model.jobs.map(\.inputURL.lastPathComponent) == [
            "one.mp4", "two.MOV",
        ])
        #expect(model.jobs.allSatisfy { $0.state == .ready })
        #expect(model.selectedJobID == model.jobs.first?.id)
        #expect(model.validationMessage?.contains("skipped") == true)
        let calls = await coordinator.recordedCalls()
        #expect(calls.addedInputs.map(\.lastPathComponent) == [
            "one.mp4", "two.MOV",
        ])
        #expect(calls.prepareCount == 2)
        #expect(calls.startQueueCount == 0)
    }

    @Test("Import deduplicates normalized paths without replacing the original URL")
    func importPreservesOriginalURLWhileDeduplicating() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        let originalURL = URL(
            fileURLWithPath: "/tmp/security-scope/../source.mp4"
        )
        let duplicateURL = originalURL.standardizedFileURL

        #expect(originalURL != duplicateURL)
        await model.importVideos([originalURL, duplicateURL])

        let job = try #require(model.jobs.first)
        let calls = await coordinator.recordedCalls()
        #expect(model.jobs.count == 1)
        #expect(job.inputURL == originalURL)
        #expect(calls.addedInputs == [originalURL])
        #expect(model.validationMessage?.contains("skipped") == true)
    }

    @Test("Adding a batch while another job runs never replaces it")
    func addWhileRunningIsNonDestructive() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/active.mp4"))
        let activeID = try #require(model.selectedJobID)
        try await coordinator.replaceWithRunningJob(jobID: activeID)
        #expect(await eventually { model.snapshot.activeJobID == activeID })

        await model.importVideos([
            URL(fileURLWithPath: "/tmp/second.mov"),
            URL(fileURLWithPath: "/tmp/third.mp4"),
        ])

        #expect(model.jobs.count == 3)
        #expect(model.job(id: activeID)?.state.phase == .running)
        #expect(model.selectedJobID != activeID)
        #expect((await coordinator.recordedCalls()).cancelledJobIDs.isEmpty)
    }

    @Test("Start captures one typed configuration for every ready job")
    func startCapturesBatchConfiguration() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mov"),
        ])

        await model.start()
        #expect((await coordinator.recordedCalls()).enqueuedJobIDs.isEmpty)
        #expect(model.validationMessage?.contains("output folder") == true)

        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start(
            filenameSuffix: "-web",
            conflictPolicy: .fail
        )

        let calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs == model.jobs.map(\.id))
        #expect(calls.startQueueCount == 1)
        #expect(calls.configurations.count == 2)
        for configuration in calls.configurations.values {
            #expect(configuration.recipe == (
                try AutomaticCompressionPolicy().recipe(
                    for: TestFixtures.mediaInfo()
                )
            ))
            #expect(configuration.outputPolicy.filenameSuffix == "-web")
            #expect(configuration.outputPolicy.conflictPolicy == .fail)
        }
        #expect(model.snapshot.activeJobID == model.jobs.first?.id)
        #expect(model.snapshot.queuedJobIDs == [model.jobs[1].id])
    }

    @Test("Compression drafts default to Quick and stay isolated per video")
    func compressionDraftsArePerJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/quick.mp4"),
            URL(fileURLWithPath: "/tmp/flexible.mp4"),
        ])
        let quickID = model.jobs[0].id
        let flexibleID = model.jobs[1].id

        #expect(model.compressionDraft(for: quickID) == CompressionDraftSettings())
        #expect(model.compressionDraft(for: flexibleID) == CompressionDraftSettings())

        model.setCompressionControlMode(.flexible, jobID: flexibleID)
        model.setFlexibleQuality(0.80, jobID: flexibleID)
        model.setFlexibleResolution(.p720, jobID: flexibleID)
        model.setFlexibleFrameRate(.fps24, jobID: flexibleID)
        model.setKeepsAudio(false, jobID: flexibleID)

        #expect(model.compressionDraft(for: quickID) == CompressionDraftSettings())
        #expect(
            model.compressionDraft(for: flexibleID) == CompressionDraftSettings(
                controlMode: .flexible,
                quality: 0.80,
                resolution: .p720,
                frameRate: .fps24,
                audioPreference: .remove
            )
        )
    }

    @Test("Quick captures the user's remove-audio choice")
    func quickCanRemoveAudio() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/with-audio.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.setKeepsAudio(false, jobID: jobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )

        await model.start()

        let recipe = try #require(
            (await coordinator.recordedCalls()).configurations[jobID]?.recipe
        )
        #expect(recipe.origin == .primary(.quick(audio: .remove)))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Flexible captures bounded settings while Quick keeps its defaults")
    func flexibleSettingsAreCapturedPerJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/flexible.mp4"),
            URL(fileURLWithPath: "/tmp/quick.mp4"),
        ])
        let flexibleID = model.jobs[0].id
        let quickID = model.jobs[1].id
        model.setCompressionControlMode(.flexible, jobID: flexibleID)
        model.setFlexibleQuality(1, jobID: flexibleID)
        model.setFlexibleResolution(.p480, jobID: flexibleID)
        model.setFlexibleFrameRate(.fps60, jobID: flexibleID)
        model.setKeepsAudio(false, jobID: flexibleID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )

        await model.start()

        model.setCompressionControlMode(.quick, jobID: flexibleID)
        model.setFlexibleQuality(0.30, jobID: flexibleID)
        model.setKeepsAudio(true, jobID: flexibleID)

        let configurations = await coordinator.recordedCalls().configurations
        let flexibleRecipe = try #require(configurations[flexibleID]?.recipe)
        let expectedSettings = PrimaryCompressionSettings.flexible(
            try FlexibleCompressionSettings(
                quality: VideoQuality(0.90),
                resolution: .p480,
                frameRate: .fps60,
                audioPreference: .remove
            )
        )
        #expect(flexibleRecipe.origin == .primary(expectedSettings))
        #expect(flexibleRecipe.rateControl == .quality(try VideoQuality(0.90)))
        #expect(
            flexibleRecipe.scalePolicy == .maximum(
                try ResolutionLimit(
                    maximumLongEdge: 854,
                    maximumShortEdge: 480
                )
            )
        )
        #expect(
            flexibleRecipe.frameRatePolicy == .capped(
                try FrameRateLimit(framesPerSecond: 60)
            )
        )
        #expect(flexibleRecipe.audioPolicy == .remove)
        #expect(
            model.compressionDraft(for: flexibleID).controlMode == .flexible
        )
        #expect(model.compressionDraft(for: flexibleID).quality == 0.90)
        #expect(
            model.compressionDraft(for: flexibleID).audioPreference == .remove
        )
        #expect(
            configurations[quickID]?.recipe.origin
                == .primary(.quick(audio: .keep))
        )
    }

    @Test("Automatic recipes are derived independently for mixed-audio batches")
    func automaticRecipesUseEachJobsMediaInfo() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/with-audio.mp4"),
            URL(fileURLWithPath: "/tmp/silent.mp4"),
        ])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )

        await model.start()

        let calls = await coordinator.recordedCalls()
        let audioJob = try #require(
            model.jobs.first { $0.inputURL.lastPathComponent == "with-audio.mp4" }
        )
        let silentJob = try #require(
            model.jobs.first { $0.inputURL.lastPathComponent == "silent.mp4" }
        )
        #expect(
            calls.configurations[audioJob.id]?.recipe.audioPolicy
                == .aac(try AudioBitRate(bitsPerSecond: 128_000))
        )
        #expect(
            calls.configurations[silentJob.id]?.recipe.audioPolicy == .remove
        )
    }

    @Test("Compress More creates a compact job from the original")
    func compressMoreUsesOriginalAndKeepsCompletedResult() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        let inputURL = URL(fileURLWithPath: "/tmp/original.mp4")
        let outputURL = URL(fileURLWithPath: "/tmp/export/result.mp4")
        await model.importVideo(inputURL)
        let sourceID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        try await coordinator.replaceWithCompletedJob(
            jobID: sourceID,
            outputURL: outputURL
        )
        #expect(await eventually { model.canCompressMore(jobID: sourceID) })

        await model.compressMore(
            jobID: sourceID,
            filenameSuffix: "-web",
            conflictPolicy: .fail
        )

        let compactJob = try #require(model.jobs.last)
        #expect(compactJob.id != sourceID)
        #expect(compactJob.mode == .compactRetry)
        #expect(compactJob.inputURL == inputURL)
        #expect(compactJob.inputURL != outputURL)
        #expect(
            compactJob.configuration?.recipe.origin
                == .compactRetry(audio: .keep)
        )
        #expect(
            compactJob.configuration?.outputPolicy.filenameSuffix
                == "-web-smaller"
        )
        #expect(!model.canCompressMore(jobID: compactJob.id))
        #expect(model.job(id: sourceID)?.state.phase == .completed)
    }

    @Test("Compress More inherits the Quick remove-audio choice")
    func compressMoreInheritsAudioRemoval() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/original.mp4"))
        let sourceID = try #require(model.selectedJobID)
        model.setKeepsAudio(false, jobID: sourceID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        try await coordinator.replaceWithCompletedJob(
            jobID: sourceID,
            outputURL: URL(fileURLWithPath: "/tmp/export/result.mp4")
        )
        #expect(await eventually { model.canCompressMore(jobID: sourceID) })

        await model.compressMore(jobID: sourceID)

        let compactJob = try #require(model.jobs.last)
        #expect(compactJob.mode == .compactRetry)
        #expect(
            compactJob.configuration?.recipe.origin
                == .compactRetry(audio: .remove)
        )
        #expect(compactJob.configuration?.recipe.audioPolicy == .remove)
    }

    @Test("Flexible results do not offer the fixed Quick compact retry")
    func flexibleResultDoesNotOfferCompressMore() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/flexible.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.setCompressionControlMode(.flexible, jobID: jobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        try await coordinator.replaceWithCompletedJob(
            jobID: jobID,
            outputURL: URL(fileURLWithPath: "/tmp/export/result.mp4")
        )

        #expect(await eventually {
            model.job(id: jobID)?.state.phase == .completed
        })
        #expect(!model.canCompressMore(jobID: jobID))
    }

    @Test("Compact probe retry preserves removed audio for a later Start")
    func compactProbeRetryCanBeStartedWithInheritedAudio() async throws {
        let (model, coordinator, compactID) = try await
            makeReadyCompactJobAfterProbeFailure(audio: .remove)

        await model.start()

        let calls = await coordinator.recordedCalls()
        let recipe = try #require(calls.configurations[compactID]?.recipe)
        #expect(calls.enqueuedJobIDs.last == compactID)
        #expect(recipe.origin == .compactRetry(audio: .remove))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Cancelled unconfigured primary job derives its current draft recipe")
    func cancelledPrimaryWithoutConfigurationCanRetry() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/cancelled.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.setCompressionControlMode(.flexible, jobID: jobID)
        model.setFlexibleQuality(0.40, jobID: jobID)
        model.setFlexibleResolution(.p720, jobID: jobID)
        model.setFlexibleFrameRate(.fps24, jobID: jobID)
        model.setKeepsAudio(false, jobID: jobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        try await coordinator.replaceWithUnconfiguredCancelledJob(
            jobID: jobID
        )
        #expect(await eventually {
            model.job(id: jobID)?.state == .cancelled
        })
        #expect(model.job(id: jobID)?.configuration == nil)

        await model.retry(jobID: jobID)

        let recipe = try #require(
            (await coordinator.recordedCalls()).configurations[jobID]?.recipe
        )
        let expectedSettings = PrimaryCompressionSettings.flexible(
            try FlexibleCompressionSettings(
                quality: VideoQuality(0.40),
                resolution: .p720,
                frameRate: .fps24,
                audioPreference: .remove
            )
        )
        #expect(recipe.origin == .primary(expectedSettings))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Cancelled unconfigured compact job derives its inherited recipe")
    func cancelledCompactWithoutConfigurationCanRetry() async throws {
        let (model, coordinator, compactID) = try await
            makeReadyCompactJobAfterProbeFailure(audio: .remove)
        try await coordinator.replaceWithUnconfiguredCancelledJob(
            jobID: compactID
        )
        #expect(await eventually {
            model.job(id: compactID)?.state == .cancelled
        })
        #expect(model.job(id: compactID)?.configuration == nil)

        await model.retry(jobID: compactID)

        let recipe = try #require(
            (await coordinator.recordedCalls()).configurations[compactID]?.recipe
        )
        #expect(recipe.origin == .compactRetry(audio: .remove))
        #expect(recipe.audioPolicy == .remove)
    }

    @Test("Compact preparation cannot be admitted by the general Start action")
    func compactPreparationIsAdmittedExactlyOnce() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/original.mp4"))
        let sourceID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        try await coordinator.replaceWithCompletedJob(
            jobID: sourceID,
            outputURL: URL(fileURLWithPath: "/tmp/export/result.mp4")
        )
        #expect(await eventually { model.canCompressMore(jobID: sourceID) })
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterReady(prepareGate)

        let compactTask = Task { @MainActor in
            await model.compressMore(jobID: sourceID)
        }
        let compactID = await prepareGate.waitUntilEntered()
        #expect(await eventually {
            model.job(id: compactID)?.state.phase == .ready
        })

        #expect(!model.canStart)
        await model.start()
        var calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)

        await prepareGate.release()
        await compactTask.value

        calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs == [compactID])
        #expect(calls.startQueueCount == 1)
    }

    @Test("Cancelling compact preparation stays neutral and never queues it")
    func compactPreparationCancellationIsNeutral() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/original.mp4"))
        let sourceID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        try await coordinator.replaceWithCompletedJob(
            jobID: sourceID,
            outputURL: URL(fileURLWithPath: "/tmp/export/result.mp4")
        )
        #expect(await eventually { model.canCompressMore(jobID: sourceID) })
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterProbing(prepareGate)

        let compactTask = Task { @MainActor in
            await model.compressMore(jobID: sourceID)
        }
        let compactID = await prepareGate.waitUntilEntered()
        #expect(await eventually {
            model.job(id: compactID)?.state.phase == .probing
                && model.canCancel(jobID: compactID)
        })

        await model.cancel(jobID: compactID)
        await prepareGate.release()
        await compactTask.value

        #expect(model.job(id: compactID)?.state.phase == .cancelled)
        #expect(model.validationMessage == nil)
        let calls = await coordinator.recordedCalls()
        #expect(calls.cancelledJobIDs.contains(compactID))
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
    }

    @Test("No-benefit is neutral and still offers one compact attempt")
    func noBenefitPresentationIsNotFailure() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let revealer = OutputRevealerSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            outputRevealer: revealer
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/compact.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        try await coordinator.replaceWithNoBenefitJob(jobID: jobID)

        #expect(await eventually {
            if case .noBenefit = model.screenState { return true }
            return false
        })
        #expect(model.finishedJobs.map(\.id).contains(jobID))
        #expect(model.canCompressMore(jobID: jobID))
        #expect(!model.canRetry(jobID: jobID))
        model.openResult(jobID: jobID)
        model.revealResultInFinder(jobID: jobID)
        #expect(revealer.openedURLs.isEmpty)
        #expect(revealer.revealedURLs.isEmpty)
    }

    @Test("Overlapping start calls enqueue and wake the queue exactly once")
    func overlappingStartsAreIdempotent() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/once.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let enqueueGate = SynchronousCallGate()
        await coordinator.gateNextEnqueue(enqueueGate)

        let firstStart = Task { await model.start() }
        await enqueueGate.waitUntilEntered()
        #expect(model.isStartingQueue)

        await model.start()
        #expect(model.isStartingQueue)

        enqueueGate.release()
        await firstStart.value
        let calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs == [jobID])
        #expect(calls.startQueueCount == 1)
        #expect(calls.configurations.count == 1)
    }

    @Test("A ready snapshot cannot start before its import finishes")
    func readySnapshotWaitsForImportCompletion() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterReady(prepareGate)

        let importTask = Task { @MainActor in
            await model.importVideo(
                URL(fileURLWithPath: "/tmp/preparing.mp4")
            )
        }
        let jobID = await prepareGate.waitUntilEntered()
        #expect(await eventually {
            model.isImporting && model.job(id: jobID)?.state == .ready
        })

        #expect(!model.canStart)
        await model.start()
        var calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)

        await prepareGate.release()
        await importTask.value

        #expect(model.canStart)
        calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
    }

    @Test("A ready probe-retry snapshot cannot start before retry finishes")
    func readySnapshotWaitsForProbeRetryCompletion() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(
            URL(fileURLWithPath: "/tmp/retrying-probe.mp4")
        )
        let jobID = try #require(model.selectedJobID)
        try await coordinator.replaceWithProbeFailure(jobID: jobID)
        #expect(await eventually {
            model.job(id: jobID)?.state.phase == .failed
        })
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        let prepareGate = AsyncCallGate<CompressionJob.ID>()
        await coordinator.gateNextPrepareAfterReady(prepareGate)

        let retryTask = Task { @MainActor in
            await model.retry(jobID: jobID)
        }
        #expect(await prepareGate.waitUntilEntered() == jobID)
        #expect(await eventually {
            model.pendingActionJobIDs.contains(jobID)
                && model.job(id: jobID)?.state == .ready
        })

        #expect(!model.canStart)
        await model.start()
        var calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)

        await prepareGate.release()
        await retryTask.value

        #expect(model.canStart)
        calls = await coordinator.recordedCalls()
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
    }

    @Test("Stale import snapshots preserve pending selection until user selects")
    func staleImportSnapshotPreservesPendingSelection() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/existing.mp4"))
        let existingID = try #require(model.selectedJobID)
        let addGate = AsyncCallGate<[CompressionJob.ID]>()
        await coordinator.gateNextAddBeforeCreate(addGate)

        let importTask = Task { @MainActor in
            await model.importVideo(URL(fileURLWithPath: "/tmp/new.mp4"))
        }
        let importedID = try #require(
            await addGate.waitUntilEntered().first
        )

        // A valid concurrent queue update does not contain the not-yet-added
        // import ID. Consuming it must not replace the pending selection.
        try await coordinator.replaceWithRunningJob(jobID: existingID)
        #expect(await eventually {
            model.snapshot.activeJobID == existingID
        })
        #expect(model.selectedJobID == importedID)

        // An explicit user choice wins over the automatic import selection.
        model.selectJob(existingID)
        await addGate.release()
        await importTask.value

        #expect(model.selectedJobID == existingID)
        #expect(model.job(id: importedID)?.state == .ready)
    }

    @Test("A lower revision cannot overtake a completed import")
    func lowerRevisionCannotOvertakeCompletedImport() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/old.mp4"))
        let staleSnapshot = await coordinator.snapshot()

        await model.importVideo(URL(fileURLWithPath: "/tmp/fresh.mp4"))
        let importedID = try #require(model.selectedJobID)
        let freshSnapshot = model.snapshot
        #expect(freshSnapshot.revision > staleSnapshot.revision)
        #expect(freshSnapshot.jobs.count == 2)
        #expect(model.job(id: importedID)?.inputURL.lastPathComponent == "fresh.mp4")

        // Deliver the captured snapshot through the same direct-sync seam
        // used by model actions. This avoids scheduler timing in the stream
        // while reproducing an older response arriving after the import.
        await coordinator.replayOnNextSnapshotRead(staleSnapshot)
        await model.refresh()

        #expect(model.snapshot == freshSnapshot)
        #expect(model.selectedJobID == importedID)
        #expect(model.jobs.map(\.inputURL.lastPathComponent) == [
            "old.mp4", "fresh.mp4",
        ])
    }

    @Test("Cancel targets one waiting job without disturbing the active job")
    func explicitQueuedCancellation() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
        ])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        let activeID = try #require(model.snapshot.activeJobID)
        let waitingID = try #require(model.snapshot.queuedJobIDs.first)

        await model.cancel(jobID: waitingID)

        #expect(model.job(id: waitingID)?.state == .cancelled)
        #expect(model.job(id: activeID)?.state.phase == .running)
        #expect((await coordinator.recordedCalls()).cancelledJobIDs == [
            waitingID,
        ])
    }

    @Test("Waiting jobs can be reordered and removed with stable selection")
    func reorderAndRemoveWaitingJobs() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/a.mp4"),
            URL(fileURLWithPath: "/tmp/b.mp4"),
            URL(fileURLWithPath: "/tmp/c.mp4"),
        ])
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        let activeID = try #require(model.snapshot.activeJobID)
        let secondID = model.snapshot.queuedJobIDs[0]
        let thirdID = model.snapshot.queuedJobIDs[1]
        model.selectJob(thirdID)

        await model.moveSelectedUp()
        #expect(model.snapshot.queuedJobIDs == [thirdID, secondID])

        await model.removeSelectedJob()
        #expect(model.job(id: thirdID) == nil)
        #expect(model.snapshot.queuedJobIDs == [secondID])
        #expect(model.selectedJobID == activeID)
        let calls = await coordinator.recordedCalls()
        #expect(calls.removedJobIDs == [thirdID])
    }

    @Test("A ready attached video can be removed and selection falls back")
    func readyVideoCanBeRemoved() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/keep.mp4"),
            URL(fileURLWithPath: "/tmp/remove.mp4"),
        ])
        let fallbackID = model.jobs[0].id
        let removedID = model.jobs[1].id
        model.selectJob(removedID)

        #expect(model.canRemove(jobID: removedID))
        await model.removeSelectedJob()

        #expect(model.job(id: removedID) == nil)
        #expect(model.selectedJobID == fallbackID)
        #expect(model.compressionDrafts[removedID] == nil)
        #expect((await coordinator.recordedCalls()).removedJobIDs == [removedID])
    }

    @Test("Overlapping remove actions mutate the coordinator only once")
    func overlappingRemoveIsIdempotent() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/remove-once.mp4"))
        let jobID = try #require(model.selectedJobID)
        let gate = SynchronousCallGate()
        await coordinator.gateNextRemove(gate)

        let firstRemove = Task { @MainActor in
            await model.removeJob(jobID: jobID)
        }
        await gate.waitUntilEntered()
        #expect(model.pendingActionJobIDs.contains(jobID))

        await model.removeJob(jobID: jobID)
        gate.release()
        await firstRemove.value

        #expect((await coordinator.recordedCalls()).removedJobIDs == [jobID])
        #expect(model.job(id: jobID) == nil)
        #expect(model.validationMessage == nil)
    }

    @Test("Retry preserves identity and copies only bounded diagnostics")
    func retryAndDiagnostics() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let copier = DiagnosticCopierSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            diagnosticCopier: copier
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/source.mp4"))
        let jobID = try #require(model.selectedJobID)
        let diagnostic = try BoundedDiagnostic(
            text: "bounded encoder tail",
            utf8ByteLimit: 64,
            wasTruncated: false
        )
        try await coordinator.replaceWithEncodeFailure(
            jobID: jobID,
            diagnostic: diagnostic
        )
        #expect(await eventually {
            model.diagnosticText?.contains(diagnostic.text) == true
        })

        model.copyDiagnostics(jobID: jobID)
        let copiedReport = try #require(copier.copiedTexts.first)
        #expect(copiedReport.contains(diagnostic.text))
        #expect(copiedReport.contains("8.1.2"))
        #expect(copiedReport.contains("process_failed"))
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/retry", isDirectory: true)
        )
        await model.retry(jobID: jobID, filenameSuffix: "-retry")

        let calls = await coordinator.recordedCalls()
        #expect(calls.retriedJobIDs == [jobID])
        #expect(calls.configurations[jobID]?.outputPolicy.filenameSuffix == "-retry")
        #expect(model.job(id: jobID) != nil)
        #expect(model.snapshot.activeJobID == jobID)
    }

    @Test("Retry reuses the recipe captured before Flexible encoding")
    func retryPreservesCapturedFlexibleRecipe() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/flexible.mp4"))
        let jobID = try #require(model.selectedJobID)
        model.setCompressionControlMode(.flexible, jobID: jobID)
        model.setFlexibleQuality(0.35, jobID: jobID)
        model.setFlexibleResolution(.source, jobID: jobID)
        model.setFlexibleFrameRate(.source, jobID: jobID)
        model.setKeepsAudio(false, jobID: jobID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        let capturedRecipe = try #require(
            (await coordinator.recordedCalls()).configurations[jobID]?.recipe
        )
        try await coordinator.replaceWithEncodeFailure(
            jobID: jobID,
            diagnostic: BoundedDiagnostic(
                text: "encode failed",
                utf8ByteLimit: 64,
                wasTruncated: false
            )
        )
        #expect(await eventually { model.canRetry(jobID: jobID) })

        await model.retry(jobID: jobID, filenameSuffix: "-retry")

        let retried = try #require(
            (await coordinator.recordedCalls()).configurations[jobID]
        )
        #expect(retried.recipe == capturedRecipe)
        #expect(retried.outputPolicy.filenameSuffix == "-retry")
    }

    @Test("Probe failure retries preparation without requiring an output folder")
    func probeFailureRetryReturnsToReady() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/probe-failure.mp4"))
        let jobID = try #require(model.selectedJobID)
        try await coordinator.replaceWithProbeFailure(jobID: jobID)
        #expect(await eventually {
            model.job(id: jobID)?.state.phase == .failed
        })
        let prepareCountBeforeRetry = await coordinator.recordedCalls()
            .prepareCount

        #expect(model.outputDirectoryURL == nil)
        #expect(model.canRetry(jobID: jobID))
        await model.retry(jobID: jobID)

        let calls = await coordinator.recordedCalls()
        #expect(calls.prepareCount == prepareCountBeforeRetry + 1)
        #expect(calls.retriedJobIDs.isEmpty)
        #expect(calls.enqueuedJobIDs.isEmpty)
        #expect(calls.startQueueCount == 0)
        #expect(model.job(id: jobID)?.state == .ready)
        #expect(model.selectedJobID == jobID)
    }

    @Test("ETA follows the active encode instead of sidebar selection")
    func etaUsesActiveJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/active.mp4"),
            URL(fileURLWithPath: "/tmp/selected.mp4"),
        ])
        let activeID = model.jobs[0].id
        let selectedID = model.jobs[1].id
        try await coordinator.replaceWithRunningJob(jobID: activeID)
        model.selectJob(selectedID)

        for sample in [(3_000_000, 2.0), (4_000_000, 2.1), (5_000_000, 1.9)] {
            try await coordinator.sendProgress(
                jobID: activeID,
                processedMicroseconds: Int64(sample.0),
                totalMicroseconds: 20_000_000,
                speed: sample.1
            )
            #expect(await eventually {
                model.activeProgressMicroseconds == Int64(sample.0)
            })
        }

        #expect(model.selectedJobID == selectedID)
        #expect(model.estimatedRemainingSeconds == 7.5)
    }

    @Test("Unchanged active progress snapshot preserves a mature ETA")
    func unchangedProgressSnapshotPreservesETA() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/active.mp4"))
        let activeID = try #require(model.selectedJobID)
        try await coordinator.replaceWithRunningJob(jobID: activeID)

        for sample in [(3_000_000, 2.0), (4_000_000, 2.1), (5_000_000, 1.9)] {
            try await coordinator.sendProgress(
                jobID: activeID,
                processedMicroseconds: Int64(sample.0),
                totalMicroseconds: 20_000_000,
                speed: sample.1
            )
            #expect(await eventually {
                model.activeProgressMicroseconds == Int64(sample.0)
            })
        }
        let matureETA = try #require(model.estimatedRemainingSeconds)

        await model.refresh()

        #expect(model.estimatedRemainingSeconds == matureETA)
    }

    @Test("Nil selection cannot deselect a nonempty queue")
    func nilSelectionPreservesExistingSelection() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/first.mp4"),
            URL(fileURLWithPath: "/tmp/second.mp4"),
        ])
        let secondID = model.jobs[1].id
        model.selectJob(secondID)

        model.selectJob(nil)

        #expect(model.selectedJobID == secondID)
        #expect(model.currentJob?.id == secondID)
    }

    @Test("Completed results can be revealed by explicit queue identity")
    func revealExplicitCompletedJob() async throws {
        let coordinator = QueueFeatureCoordinatorFake()
        let revealer = OutputRevealerSpy()
        let model = CompressionFeatureModel(
            coordinator: coordinator,
            outputRevealer: revealer
        )
        await coordinator.waitUntilSubscribed()
        await model.importVideos([
            URL(fileURLWithPath: "/tmp/done.mp4"),
            URL(fileURLWithPath: "/tmp/other.mp4"),
        ])
        let completedID = model.jobs[0].id
        let otherID = model.jobs[1].id
        let outputURL = URL(fileURLWithPath: "/tmp/export/done.mp4")
        try await coordinator.replaceWithCompletedJob(
            jobID: completedID,
            outputURL: outputURL
        )
        #expect(await eventually {
            guard let completed = model.job(id: completedID),
                  case .completed = completed.state else {
                return false
            }
            return true
        })
        model.selectJob(otherID)

        model.openResult(jobID: completedID)
        model.revealResultInFinder(jobID: completedID)

        #expect(revealer.openedURLs == [outputURL])
        #expect(revealer.revealedURLs == [outputURL])
        #expect(model.selectedJobID == otherID)
    }

    @Test("Application shutdown is forwarded to the queue coordinator")
    func shutdownForwarding() async {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()

        await model.shutdown()

        #expect((await coordinator.recordedCalls()).shutdownCount == 1)
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func makeReadyCompactJobAfterProbeFailure(
        audio: AudioPreference
    ) async throws -> (
        CompressionFeatureModel,
        QueueFeatureCoordinatorFake,
        CompressionJob.ID
    ) {
        let coordinator = QueueFeatureCoordinatorFake()
        let model = CompressionFeatureModel(coordinator: coordinator)
        await coordinator.waitUntilSubscribed()
        await model.importVideo(URL(fileURLWithPath: "/tmp/original.mp4"))
        let sourceID = try #require(model.selectedJobID)
        model.setKeepsAudio(audio == .keep, jobID: sourceID)
        model.selectOutputDirectory(
            URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        )
        await model.start()
        try await coordinator.replaceWithCompletedJob(
            jobID: sourceID,
            outputURL: URL(fileURLWithPath: "/tmp/export/result.mp4")
        )
        #expect(await eventually { model.canCompressMore(jobID: sourceID) })
        await coordinator.failNextCompactPreparation()

        await model.compressMore(jobID: sourceID)

        let compactID = try #require(model.selectedJobID)
        #expect(await eventually {
            guard let job = model.job(id: compactID),
                  case .failed(let failure) = job.state else {
                return false
            }
            return job.mode == .compactRetry && failure.stage == .probe
        })
        #expect(model.compactAudioPreference(for: compactID) == audio)

        await model.retry(jobID: compactID)

        #expect(model.job(id: compactID)?.state == .ready)
        #expect(model.job(id: compactID)?.configuration == nil)
        return (model, coordinator, compactID)
    }
}

private extension CompressionFeatureModel {
    var activeProgressMicroseconds: Int64? {
        guard let activeJob,
              case .running(let progress) = activeJob.state else {
            return nil
        }
        return progress?.processedMicroseconds
    }
}

@MainActor
private final class OutputRevealerSpy: OutputRevealing {
    private(set) var openedURLs: [URL] = []
    private(set) var revealedURLs: [URL] = []

    func open(_ outputURL: URL) {
        openedURLs.append(outputURL)
    }

    func reveal(_ outputURL: URL) {
        revealedURLs.append(outputURL)
    }
}

@MainActor
private final class DiagnosticCopierSpy: DiagnosticCopying {
    private(set) var copiedTexts: [String] = []

    func copyDiagnostic(_ text: String) {
        copiedTexts.append(text)
    }
}

private final class SynchronousCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() {
        lock.lock()
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
        releaseSignal.wait()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didEnter {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        releaseSignal.signal()
    }
}

private actor AsyncCallGate<Value: Sendable> {
    private var enteredValue: Value?
    private var entryWaiters: [CheckedContinuation<Value, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func enterAndWait(_ value: Value) async {
        enteredValue = value
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilEntered() async -> Value {
        if let enteredValue { return enteredValue }
        return await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        waiter?.resume()
    }
}

private actor QueueFeatureCoordinatorFake: JobQueueCoordinating {
    nonisolated struct Calls: Sendable {
        var addedInputs: [URL] = []
        var prepareCount = 0
        var enqueuedJobIDs: [CompressionJob.ID] = []
        var configurations: [CompressionJob.ID: JobConfiguration] = [:]
        var startQueueCount = 0
        var retriedJobIDs: [CompressionJob.ID] = []
        var cancelledJobIDs: [CompressionJob.ID] = []
        var removedJobIDs: [CompressionJob.ID] = []
        var shutdownCount = 0
    }

    private var calls = Calls()
    private var jobsByID: [CompressionJob.ID: CompressionJob] = [:]
    private var jobOrder: [CompressionJob.ID] = []
    private var activeJobID: CompressionJob.ID?
    private var snapshotRevision: UInt64 = 0
    private var replayedSnapshotForNextDirectRead: CompressionSnapshot?
    private var continuations: [
        UUID: AsyncStream<CompressionSnapshot>.Continuation
    ] = [:]
    private var hasSubscriber = false
    private var subscriberWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextEnqueueGate: SynchronousCallGate?
    private var nextPrepareAfterProbingGate: AsyncCallGate<CompressionJob.ID>?
    private var nextPrepareAfterReadyGate: AsyncCallGate<CompressionJob.ID>?
    private var nextAddBeforeCreateGate: AsyncCallGate<[CompressionJob.ID]>?
    private var nextRemoveGate: SynchronousCallGate?
    private var failsNextCompactPreparation = false

    @discardableResult
    func add(
        _ imports: [JobQueueImport]
    ) async throws -> [CompressionJob.ID] {
        if let gate = nextAddBeforeCreateGate {
            nextAddBeforeCreateGate = nil
            await gate.enterAndWait(imports.map(\.id))
        }
        for item in imports {
            let job = try CompressionJob(
                id: item.id,
                inputURL: item.inputURL,
                createdAt: item.createdAt,
                mode: item.mode
            )
            jobsByID[item.id] = job
            jobOrder.append(item.id)
            publish()
            calls.addedInputs.append(item.inputURL)
        }
        for item in imports {
            _ = try await prepare(jobID: item.id)
        }
        return imports.map(\.id)
    }

    func createJob(
        inputURL: URL,
        id: CompressionJob.ID,
        createdAt: Date
    ) throws -> CompressionJob {
        let job = try CompressionJob(
            id: id,
            inputURL: inputURL,
            createdAt: createdAt
        )
        jobsByID[id] = job
        jobOrder.append(id)
        publish()
        return job
    }

    func prepare(jobID: CompressionJob.ID) async throws -> CompressionJob {
        calls.prepareCount += 1
        var job = try requireJob(jobID)
        try job.transition(to: .probing)
        jobsByID[jobID] = job
        publish()
        if failsNextCompactPreparation, job.mode == .compactRetry {
            failsNextCompactPreparation = false
            let failure = TranscodeFailure(
                stage: .probe,
                reason: .invalidMedia,
                diagnosticTail: nil
            )
            try job.transition(to: .failed(failure))
            jobsByID[jobID] = job
            publish()
            throw failure
        }
        if let gate = nextPrepareAfterProbingGate {
            nextPrepareAfterProbingGate = nil
            await gate.enterAndWait(jobID)
            job = try requireJob(jobID)
            if case .cancelled = job.state {
                return job
            }
        }
        try job.recordMediaInfo(try mediaInfo(for: job))
        try job.transition(to: .ready)
        jobsByID[jobID] = job
        publish()
        if let gate = nextPrepareAfterReadyGate {
            nextPrepareAfterReadyGate = nil
            await gate.enterAndWait(jobID)
        }
        return job
    }

    @discardableResult
    func enqueue(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) throws -> CompressionJob {
        if let gate = nextEnqueueGate {
            nextEnqueueGate = nil
            gate.enterAndWait()
        }
        var job = try requireJob(jobID)
        switch job.state {
        case .ready:
            break
        case .failed(let failure) where failure.retryTarget == .ready:
            try job.transition(to: .ready)
        case .cancelled where job.mediaInfo != nil:
            try job.transition(to: .ready)
        default:
            throw CompressionWorkflowError.workflowStateChanged(job.state.phase)
        }
        try job.configure(configuration)
        try job.transition(to: .queued)
        jobsByID[jobID] = job
        calls.enqueuedJobIDs.append(jobID)
        calls.configurations[jobID] = configuration
        publish()
        return job
    }

    func startQueue() {
        calls.startQueueCount += 1
        guard activeJobID == nil,
              let jobID = firstWaitingJobID(),
              var job = jobsByID[jobID] else {
            publish()
            return
        }
        activeJobID = jobID
        try? job.transition(to: .running(progress: nil))
        jobsByID[jobID] = job
        publish()
    }

    @discardableResult
    func retryQueued(
        jobID: CompressionJob.ID,
        configuration: JobConfiguration
    ) async throws -> CompressionJob {
        var job = try requireJob(jobID)
        switch job.state {
        case .failed(let failure) where failure.retryTarget == .probing:
            let old = job
            job = try CompressionJob(
                id: old.id,
                inputURL: old.inputURL,
                createdAt: old.createdAt,
                mode: old.mode
            )
            try job.transition(to: .probing)
            try job.recordMediaInfo(TestFixtures.mediaInfo())
            try job.transition(to: .ready)
        case .cancelled where job.mediaInfo == nil:
            let old = job
            job = try CompressionJob(
                id: old.id,
                inputURL: old.inputURL,
                createdAt: old.createdAt,
                mode: old.mode
            )
            try job.transition(to: .probing)
            try job.recordMediaInfo(TestFixtures.mediaInfo())
            try job.transition(to: .ready)
        case .failed, .cancelled:
            try job.transition(to: .ready)
        default:
            throw CompressionWorkflowError.workflowStateChanged(job.state.phase)
        }
        jobsByID[jobID] = job
        jobOrder.removeAll { $0 == jobID }
        jobOrder.append(jobID)
        calls.retriedJobIDs.append(jobID)
        let queued = try enqueue(
            jobID: jobID,
            configuration: configuration
        )
        startQueue()
        return queued
    }

    func moveQueued(
        jobID: CompressionJob.ID,
        before successorID: CompressionJob.ID?
    ) throws {
        try requireWaiting(jobID)
        if let successorID { try requireWaiting(successorID) }
        jobOrder.removeAll { $0 == jobID }
        if let successorID,
           let index = jobOrder.firstIndex(of: successorID) {
            jobOrder.insert(jobID, at: index)
        } else {
            jobOrder.append(jobID)
        }
        publish()
    }

    func removeJob(jobID: CompressionJob.ID) throws {
        let job = try requireJob(jobID)
        if let gate = nextRemoveGate {
            nextRemoveGate = nil
            gate.enterAndWait()
        }
        guard jobID != activeJobID else {
            throw CompressionCoordinatorError.activeQueueJob(jobID)
        }
        switch job.state {
        case .ready, .queued, .cancelled, .completed, .noBenefit, .failed:
            break
        case .draft, .probing, .running, .finishing, .cancelling:
            throw CompressionCoordinatorError.jobNotRemovable(jobID)
        }
        jobsByID.removeValue(forKey: jobID)
        jobOrder.removeAll { $0 == jobID }
        calls.removedJobIDs.append(jobID)
        publish()
    }

    func cancel(jobID: CompressionJob.ID) async {
        calls.cancelledJobIDs.append(jobID)
        guard var job = jobsByID[jobID] else { return }
        do {
            switch job.state {
            case .running(let progress):
                try job.transition(to: .cancelling(lastProgress: progress))
                try job.transition(to: .cancelled)
            case .draft, .probing, .ready, .queued:
                try job.transition(to: .cancelled)
            case .finishing, .cancelling, .cancelled, .completed,
                 .noBenefit, .failed:
                return
            }
            jobsByID[jobID] = job
            if activeJobID == jobID { activeJobID = nil }
            publish()
        } catch {
            Issue.record("Fake cancellation failed: \(error)")
        }
    }

    func shutdown() async {
        calls.shutdownCount += 1
    }

    func snapshot() -> CompressionSnapshot {
        if let replayedSnapshotForNextDirectRead {
            self.replayedSnapshotForNextDirectRead = nil
            return replayedSnapshotForNextDirectRead
        }
        return currentSnapshot()
    }

    func replayOnNextSnapshotRead(_ snapshot: CompressionSnapshot) {
        replayedSnapshotForNextDirectRead = snapshot
    }

    private func currentSnapshot() -> CompressionSnapshot {
        CompressionSnapshot(
            jobs: jobOrder.compactMap { jobsByID[$0] },
            activeJobID: activeJobID,
            isDraining: activeJobID != nil,
            revision: snapshotRevision
        )
    }

    func snapshots() -> AsyncStream<CompressionSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<CompressionSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        pair.continuation.yield(currentSnapshot())
        hasSubscriber = true
        let waiters = subscriberWaiters
        subscriberWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return pair.stream
    }

    func waitUntilSubscribed() async {
        if hasSubscriber { return }
        await withCheckedContinuation { continuation in
            subscriberWaiters.append(continuation)
        }
    }

    func recordedCalls() -> Calls {
        calls
    }

    func gateNextEnqueue(_ gate: SynchronousCallGate) {
        nextEnqueueGate = gate
    }

    func gateNextPrepareAfterReady(
        _ gate: AsyncCallGate<CompressionJob.ID>
    ) {
        nextPrepareAfterReadyGate = gate
    }

    func gateNextPrepareAfterProbing(
        _ gate: AsyncCallGate<CompressionJob.ID>
    ) {
        nextPrepareAfterProbingGate = gate
    }

    func gateNextAddBeforeCreate(
        _ gate: AsyncCallGate<[CompressionJob.ID]>
    ) {
        nextAddBeforeCreateGate = gate
    }

    func gateNextRemove(_ gate: SynchronousCallGate) {
        nextRemoveGate = gate
    }

    func failNextCompactPreparation() {
        failsNextCompactPreparation = true
    }

    func replaceWithRunningJob(jobID: CompressionJob.ID) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(configuration(for: job))
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        jobsByID[jobID] = job
        activeJobID = jobID
        publish()
    }

    func replaceWithEncodeFailure(
        jobID: CompressionJob.ID,
        diagnostic: BoundedDiagnostic
    ) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(
            calls.configurations[jobID] ?? configuration(for: job)
        )
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(
            to: .failed(
                TranscodeFailure(
                    stage: .encode,
                    reason: .processFailed(exitCode: 1),
                    diagnosticTail: diagnostic
                )
            )
        )
        jobsByID[jobID] = job
        activeJobID = nil
        publish()
    }

    func replaceWithProbeFailure(jobID: CompressionJob.ID) throws {
        let old = try requireJob(jobID)
        var job = try CompressionJob(
            id: old.id,
            inputURL: old.inputURL,
            createdAt: old.createdAt,
            mode: old.mode
        )
        try job.transition(to: .probing)
        try job.transition(
            to: .failed(
                TranscodeFailure(
                    stage: .probe,
                    reason: .invalidMedia,
                    diagnosticTail: nil
                )
            )
        )
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func replaceWithUnconfiguredCancelledJob(
        jobID: CompressionJob.ID
    ) throws {
        var job = try requireJob(jobID)
        guard case .ready = job.state,
              job.mediaInfo != nil,
              job.configuration == nil else {
            throw CompressionWorkflowError.workflowStateChanged(
                job.state.phase
            )
        }
        try job.transition(to: .cancelled)
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func replaceWithCompletedJob(
        jobID: CompressionJob.ID,
        outputURL: URL
    ) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(
            calls.configurations[jobID] ?? configuration(for: job)
        )
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(to: .finishing(.validating))
        try job.transition(to: .finishing(.committing))
        try job.transition(
            to: .completed(
                try CompressionResult(
                    outputURL: outputURL,
                    sourceByteCount: 4_096,
                    outputByteCount: 2_048,
                    elapsed: .seconds(2)
                )
            )
        )
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func replaceWithNoBenefitJob(jobID: CompressionJob.ID) throws {
        var job = try makeReadyJob(jobID: jobID)
        try job.configure(
            calls.configurations[jobID] ?? configuration(for: job)
        )
        try job.transition(to: .queued)
        try job.transition(to: .running(progress: nil))
        try job.transition(to: .finishing(.validating))
        try job.transition(
            to: .noBenefit(
                CompressionNoBenefitResult(
                    sourceByteCount: 4_096,
                    candidateByteCount: 4_096,
                    elapsed: .seconds(2)
                )
            )
        )
        jobsByID[jobID] = job
        if activeJobID == jobID { activeJobID = nil }
        publish()
    }

    func sendProgress(
        jobID: CompressionJob.ID,
        processedMicroseconds: Int64,
        totalMicroseconds: Int64,
        speed: Double
    ) throws {
        var job = try requireJob(jobID)
        try job.updateProgress(
            TranscodeProgress(
                processedMicroseconds: processedMicroseconds,
                totalMicroseconds: totalMicroseconds,
                speed: speed
            )
        )
        jobsByID[jobID] = job
        publish()
    }

    private func makeReadyJob(
        jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        let old = try requireJob(jobID)
        var job = try CompressionJob(
            id: old.id,
            inputURL: old.inputURL,
            createdAt: old.createdAt,
            mode: old.mode
        )
        try job.transition(to: .probing)
        try job.recordMediaInfo(TestFixtures.mediaInfo())
        try job.transition(to: .ready)
        return job
    }

    private func mediaInfo(for job: CompressionJob) throws -> MediaInfo {
        let mediaInfo = try TestFixtures.mediaInfo()
        guard job.inputURL.lastPathComponent.contains("silent") else {
            return mediaInfo
        }
        return try MediaInfo(
            formatNames: mediaInfo.formatNames,
            durationMicroseconds: mediaInfo.durationMicroseconds,
            byteCount: mediaInfo.byteCount,
            bitRate: mediaInfo.bitRate,
            streams: mediaInfo.streams.filter { stream in
                if case .audio = stream { return false }
                return true
            }
        )
    }

    private func configuration(
        for job: CompressionJob
    ) throws -> JobConfiguration {
        guard let mediaInfo = job.mediaInfo else {
            throw CompressionJobMutationError.missingMediaInfo
        }
        let outputPolicy = try TestFixtures.configuration().outputPolicy
        return JobConfiguration(
            recipe: try AutomaticCompressionPolicy().recipe(
                for: mediaInfo,
                mode: job.mode
            ),
            outputPolicy: outputPolicy
        )
    }

    private func firstWaitingJobID() -> CompressionJob.ID? {
        jobOrder.first { id in
            guard id != activeJobID,
                  let job = jobsByID[id],
                  case .queued = job.state else {
                return false
            }
            return true
        }
    }

    private func requireWaiting(_ jobID: CompressionJob.ID) throws {
        let job = try requireJob(jobID)
        guard jobID != activeJobID,
              case .queued = job.state else {
            throw CompressionCoordinatorError.queueMutationRequiresQueued(
                jobID
            )
        }
    }

    private func requireJob(
        _ jobID: CompressionJob.ID
    ) throws -> CompressionJob {
        guard let job = jobsByID[jobID] else {
            throw CompressionCoordinatorError.jobNotFound(jobID)
        }
        return job
    }

    private func publish() {
        snapshotRevision &+= 1
        let value = currentSnapshot()
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
