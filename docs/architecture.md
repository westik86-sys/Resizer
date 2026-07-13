# Resizer architecture

This document describes the stage-3 contracts and the stage-4 process boundary.
The product workflow and FFmpeg-specific adapters are not implemented yet.

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
        -> ProcessRunner actor
            -> direct child executable
            -> concurrent stdout/stderr drains

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
remains an isolated spike. It does not use the production runner yet. The app
entry point will switch to the new composition only after real service adapters
exist.

## Process execution contract

`ProcessRunner` is an actor-owned, generic implementation of `ProcessRunning`.
It launches an absolute executable URL directly with a `[String]` argument list
and an exact controlled environment. It never constructs a shell command and
does not depend on `PATH`.

Every start uses a fresh, one-shot `ProcessExecutionID`; cancellation becomes
valid after `start` returns its stream, and IDs are never reused. The actor owns
the `Foundation.Process`, its three pipes, stream continuation, diagnostic tail,
and cancellation state. Every start also receives a private generation token,
so a late internal callback cannot be confused with newer actor state.
Independent workers receive only stdout/stderr `FileHandle` values and return
`Data` chunks, the public ID, and that token to the actor. The termination
callback sends only the ID and token back into the actor, where project-owned
status values are created.

Completion is a three-way barrier:

```text
process terminated
        + stdout EOF
        + stderr EOF
        -> one terminal ProcessResult
        -> continuation finishes once
```

The event stream has finite capacity. Dropping a stdout or stderr chunk would
make machine-readable output unsafe, so overflow becomes a typed stream failure
and starts cancellation while both pipes continue draining. Stderr also feeds a
separate fixed-capacity tail buffer for diagnostics.

Cancellation input is request policy, not FFmpeg behavior. A caller can request
closed stdin or one bounded message. Cancellation then escalates through that
message, SIGINT, SIGTERM, and SIGKILL with a liveness check between steps. The
stdin writer uses `F_SETNOSIGPIPE` so a child-exit race cannot terminate the app.
`cancel` is idempotent and awaits process termination plus both EOFs. This is a
direct-child guarantee for a normally awaiting caller. If that caller task is
itself cancelled, only its completion wait ends; actor-owned teardown continues.
Process groups and arbitrary descendants are outside the contract.

`ProcessHarness` is a C executable embedded only in `ResizerTests`. It provides
deterministic POSIX behavior for simultaneous full pipes, exit codes, literal
arguments and environment, graceful cancellation, ignored signals,
cancellation races, patterned stderr tails, and delayed EOF. Async collection
and explicit cancellation have test-level deadlines. The harness is not copied
into `Resizer.app`.

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
- `ProcessRequest` represents the executable, controlled environment, argument
  array, bounded event capacity, diagnostic limit, and generic cancellation
  policy as typed values. Arguments remain `[String]`; no shell command exists
  in the interface.
- `ProcessEvent` carries output chunks and a project-owned `ProcessResult` with
  a bounded diagnostic tail, never a framework process instance across
  isolation domains.
- Security-scoped access is expressed as one async operation so its lifetime can
  eventually cover probe, encode, validation, and commit.

The production runner now implements pipe draining, bounded diagnostics, and
direct child cancellation. Resolving bundled FFmpeg URLs and interpreting
FFmpeg/FFprobe output remain adapter responsibilities in later stages.

## Verification

`./Scripts/test.sh` covers the architecture scaffold plus real child-process
success and failure, simultaneous multi-megabyte pipes, exact bounded stderr,
literal Unicode and shell metacharacters, controlled environment, graceful and
forced cancellation, exit/cancel races, bounded stream overflow, launch
failure, and the process/EOF completion barrier. `./Scripts/build.sh` remains
the canonical build check.
