# ADR 0003: Architecture scaffold and job state contract

- Status: Accepted for implementation stage 3
- Date: 2026-07-13

## Context

After the bundled-toolchain spike, Resizer needs stable, testable contracts
before general process execution, FFprobe mapping, command construction, or
product UI are implemented. The app target uses Swift 6 strict concurrency and
defaults declarations to `MainActor`. The Xcode project also uses
file-system-synchronized groups, while ADR 0001 proposes a future local
`CompressionCore` package.

The high-level PLAN state diagram sends every failure retry to `ready`, but a
failed initial probe has no `MediaInfo` and cannot legally satisfy that state.

## Decision

Introduce five source folders in the existing app target:

- Domain owns immutable typed values, `CompressionJob`, and the complete
  `JobState` transition rules;
- Application owns async `Sendable` service ports, the coordinator actor, and
  immutable snapshots;
- Infrastructure currently contains only debug-only injectable fakes and
  project-owned process boundary values;
- UI contains a `MainActor` observable feature model;
- Composition creates the coordinator and injects all dependencies.

Keep pure models and ports explicitly `nonisolated` to neutralize the app
target's default actor isolation. Keep mutable job storage inside
`CompressionCoordinator`, allow only one active job, and expose only the feature
model from composition. Do not add a singleton or service locator.

Use associated state values for progress, finishing phases, results, failures,
and cancellation. The failure stage must match the source state and derives
`RetryTarget.probing` or `RetryTarget.ready`; callers cannot provide two
disagreeing values. Probe failures may retry only through `probing`; later
failures may retry only through `ready`. Split finishing into validation and
commit so completion cannot precede both operations.

Keep the stage-3 sources in the synchronized app target for now. Enforce the
Domain dependency rule with a unit test that rejects SwiftUI, AppKit, and any
`Process` reference. Treat migration to a local `CompressionCore` package as a
separate change that must update target dependencies and canonical test
coverage together.

Define `ProcessRunning` but do not implement it. Define transcode requests with
only the temporary URL inherited from a validated `OutputPlan`, direct argument
arrays, project-owned process events, and a terminal result with a bounded
diagnostic tail. Command requests derive from transcode requests, and transcode
results cannot substitute an output URL. Bind file cleanup to the plan instead
of accepting an arbitrary deletion URL; require job-owned temporary naming in
the selected output directory, and make commit explicitly no-replace. The
stage-2 spike runner and its temporary UI remain isolated from these production
contracts.

## Consequences

- State and configuration behavior can be tested without files, processes, or
  UI frameworks.
- Actors can own long-lived mutable workflow and process services without
  leaking framework objects across isolation domains.
- Probe retry preserves the `ready` invariant instead of fabricating media
  information.
- Validated local inputs, media, recipes, output plans, completion values, and
  bounded diagnostics reject negative or unsafe direct-path states before
  infrastructure executes them.
- The current layer boundary is convention- and test-enforced, not
  compiler-enforced. This is an explicit temporary limitation.
- `queued -> cancelled` remains intentionally absent until the queue stage adds
  a queue-specific cancellation intent.
- No general FFmpeg behavior, output commit behavior, queue, or product screen
  is delivered by this stage.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Architecture/DomainBoundaryTests.swift`
