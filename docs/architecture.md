# Resizer architecture scaffold

This document describes the stage-3 contracts. It is intentionally a scaffold:
it defines ownership, dependency direction, state transitions, and service
boundaries without launching FFmpeg or implementing the product workflow.

## Dependency direction

```text
SwiftUI views
    -> @MainActor CompressionFeatureModel
        -> CompressionCoordinator actor
            -> MediaProbing
            -> Transcoding
            -> OutputPlanning
            -> FileAccessing

Transcoding implementation (later stage)
    -> CommandBuilding
    -> ProcessRunning

AppComposition
    -> creates the coordinator
    -> injects all service implementations
```

`Domain` contains only value types and state rules. It may use Foundation value
types such as `URL`, `UUID`, `Date`, and `Duration`, but it must not import
SwiftUI or AppKit and must not reference `Process`. UI reads immutable
`CompressionSnapshot` values instead of coordinator storage.

There are no global service instances or service locators. `AppComposition`
accepts the complete coordinator dependency set and exposes only the feature
model, not the mutable coordinator. Debug previews and tests use immutable
closure-based fakes; production implementations will be added in their own PLAN
stages.

## Source layout and module boundary

The Xcode project uses file-system-synchronized groups. Stage 3 therefore keeps
`Domain`, `Application`, `Infrastructure`, `UI`, and `Composition` as folders in
the existing app target. This avoids an unrelated project migration while the
contracts are still being established.

The dependency boundary is currently enforced by source layout, code review,
and `DomainBoundaryTests`. It is not yet a compiler-enforced module boundary.
Moving Domain and Application into the planned local `CompressionCore` package
remains a deliberate later migration; package tests and the canonical scripts
must move together when that happens.

Because the app target defaults to `MainActor` isolation, pure domain and port
declarations are explicitly `nonisolated`. UI state remains explicitly
`@MainActor`, and mutable coordinator state belongs to an actor.

The visible stage-2 toolchain diagnostic predates this composition root and
remains an isolated spike. Stage 3 does not turn that diagnostic into product
UI. The app entry point will switch to the new composition only after real
service adapters exist.

## Job state contract

`JobState` is the single lifecycle source of truth. Progress updates replace the
associated value of `running` or `cancelling`; they are not lifecycle
self-transitions.

| Current state | Allowed next state |
| --- | --- |
| `draft` | `probing` |
| `probing` | `ready`, `failed(probe)` |
| `ready` | `queued` |
| `queued` | `running`, `failed(preflight)` |
| `running` | `finishing(validating)`, `cancelling`, `failed(encode)` |
| `finishing(validating)` | `finishing(committing)`, `failed(validate)` |
| `finishing(committing)` | `completed`, `failed(commit)` |
| `cancelling` | `cancelled` |
| `cancelled` | `ready` |
| `failed(retry: probing)` | `probing` |
| `failed(retry: ready)` | `ready` |
| `completed` | none |

The failure stage must match its source phase. It also derives a typed
`RetryTarget`, so stage and retry destination cannot disagree. The PLAN overview
draws every failure retry as `failed -> ready`, but probe failure is a special
case: a job without `MediaInfo` cannot satisfy the `ready` invariant and returns
to `probing`. Post-probe failures return to `ready`.

`CompressionJob` also enforces these prerequisites:

- jobs accept only local file input URLs;
- the input URL, job ID, and creation date never change;
- `ready` requires probed media information;
- `queued` and every processing/final state require both media information and
  a typed configuration;
- the coordinator permits at most one `running`, `finishing`, or `cancelling`
  job at a time;
- once cancellation wins the `running -> cancelling` transition, normal
  finishing, completion, and ordinary failure transitions are rejected;
- retrying a failed probe clears stale media and configuration before probing
  again;
- a completed result must be a non-empty local file and cannot directly resolve
  to the immutable input path.

Stage 3 follows the current overview and does not allow `queued -> cancelled`.
The queue stage must add that transition together with a queue cancellation
intent; it is not silently treated as running-process cancellation here.

## Safe service contracts

- `TranscodeRequest` can be created only from a validated `OutputPlan`, and
  `TranscodeCommandRequest` can be created only from that transcode request.
  The final URL never enters either request, and `TranscodeResult` cannot
  substitute another URL.
- `OutputPlan` binds the job, input, temporary, and final URLs and rejects direct
  path aliases. Both outputs must be MP4 files in the selected directory, and
  the `.partial.mp4` name must contain the job UUID. File cleanup accepts the
  plan rather than an arbitrary URL, and commit is explicitly no-replace.
  File-identity and symlink checks remain the responsibility of the real output
  planner.
- `ProcessRequest` represents the executable, environment, and arguments as
  typed values and requires an explicit positive diagnostic byte limit.
  Arguments remain `[String]`; no shell command exists in the interface.
- `ProcessEvent` carries output chunks and a project-owned `ProcessResult` with
  a bounded diagnostic tail, never a framework process instance across
  isolation domains.
- Security-scoped access is expressed as one async operation so its lifetime can
  eventually cover probe, encode, validation, and commit.

The actual `ProcessRunning` implementation, pipe draining, bounded diagnostics,
cancellation escalation, and direct bundled-tool launch belong to stage 4.

## Verification

`./Scripts/test.sh` covers a complete concrete transition matrix, failure-stage
matching, job prerequisites, the single-active-job invariant, immutable
snapshots, validated media/configuration/result values, safe output plans,
`MainActor` UI composition, and the recursive Domain dependency boundary.
`./Scripts/build.sh` remains the canonical build check.
