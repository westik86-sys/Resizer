# Resizer architecture

This document describes the stage-3 contracts, stage-4 process boundary,
stage-5 FFprobe adapter, and stage-6 preset, command, and output-planning
boundaries. The product workflow and FFmpeg transcode runner are not
implemented yet.

## Dependency direction

```text
SwiftUI views
    -> @MainActor CompressionFeatureModel
        -> CompressionCoordinator actor
            -> MediaProbing
            -> Transcoding
            -> OutputPlanning
            -> FileAccessing

Transcoding implementation (stage 7)
    -> CommandBuilding
        -> FFmpegCommandBuilder
    -> ProcessRunning
        -> ProcessRunner actor
            -> direct child executable
            -> concurrent stdout/stderr drains

OutputPlanning
    -> OutputPlanner actor
        -> read-only collision checks

FFprobeClient
    -> ProcessRunning
        -> bundled ffprobe

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
closure-based fakes. Production implementations now exist for process
execution, probing, command construction, and output planning; transcoding and
file publication remain later PLAN stages.

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

## FFprobe adapter contract

`FFprobeClient` is the production `MediaProbing` adapter. Its production factory
resolves `ffprobe` only with `Bundle.main.url(forAuxiliaryExecutable:)` and
resolves symlinks before rejecting a missing, non-regular, non-executable, or
out-of-bundle candidate. Tests inject an absolute executable URL and a
`ProcessRunning` implementation; neither path search nor a Homebrew fallback
exists.

Each probe starts a fresh process with one literal argument array:

```text
-v error -print_format json -show_format -show_streams -show_chapters INPUT
```

The input remains one argument even when its path contains spaces, Unicode, or
shell metacharacters. The adapter accepts stdout in arbitrary chunks, caps the
assembled JSON at 8 MiB by default, ignores streamed stderr because the runner
already retains its bounded diagnostic tail, and requires one matching terminal
result. A nonzero exit or signal becomes a typed error with termination status
and diagnostics. Overflow, malformed process event order, and invalid source or
configuration are also typed failures.

Task cancellation requests runner teardown and then awaits cancellation again
from an uncancelled cleanup task before returning. This preserves the runner's
direct-child no-orphan guarantee even though a cancelled caller does not itself
wait inside `ProcessRunner.cancel`.

JSON decoding uses transport-only DTOs. Unknown keys are ignored; absent arrays
and format data receive safe defaults; FFprobe numeric fields accept strings or
JSON numbers. String conversion consumes the complete numeric value: `N/A` is
treated as unavailable, while a present corrupt, fractional integer, or
overflowing metric is invalid metadata. Mapping then creates validated domain
values: comma-separated format names, rounded microsecond duration, byte count,
bitrate, every stream index, rational FPS, dispositions, rotation, color
metadata, and conservative HDR/SDR classification. Display-matrix rotation
takes precedence over the legacy `rotate` tag. Missing video or audio is valid,
while missing, negative, or duplicate stream indices invalidate the metadata.
Chapters are requested and decoded for forward compatibility but are not yet
part of the domain model.

## Preset and FFmpeg command contract

`CompressionRecipe(preset:)` expands the three product presets into immutable,
validated values. High Quality uses quality `0.85`, original resolution and
FPS, and AAC at 192 kbit/s. Balanced is the default and uses quality `0.65`, a
1920x1080 maximum, 30 FPS maximum, and AAC at 128 kbit/s. Small File uses
quality `0.45`, a 1280x720 maximum, 24 FPS maximum, and AAC at 96 kbit/s. All
three produce MP4 through `h264_videotoolbox` and preserve common input
metadata. Custom recipes use the same closed enums and validated value types;
there is no arbitrary-flag escape hatch.

`FFmpegCommandBuilder` is pure and stateless. It returns an ordered `[String]`
and never creates a shell command. It selects one non-attached video stream and
at most one audio stream, preferring the lowest-index default stream and then
the lowest absolute index. Those absolute indices are mapped explicitly;
subtitles, data, and unselected audio are excluded. Missing audio is valid and
becomes `-an`, as does the remove-audio policy.

Video output is H.264 VideoToolbox in `yuv420p`. Normalized quality maps to
VideoToolbox `global_quality` `1...100`; CRF and qscale are intentionally not
used. A capped frame-rate policy emits `fpsmax`, while original FPS adds no
rate override. Scaling is orientation-aware, preserves aspect ratio, never
upscales, and produces even dimensions. Autorotation is applied to pixels and
the stale output rotation tag is cleared. Known HDR and unknown-range video
above 8-bit fail closed because stage 6 does not implement tone mapping.

Every command enables bounded machine-readable progress on stdout and MP4
faststart. It deliberately leaves stdin available for stage-7 graceful `q\n`
cancellation. Preserve metadata maps only global data, selected stream data,
and chapters; remove metadata disables those input mappings. The full argument
and preset decision is recorded in
[`adr/0006-presets-command-builder.md`](adr/0006-presets-command-builder.md).

## Safe output planning contract

`OutputPlanner` is an actor with injected read-only collision checks. It
derives `source-compressed.mp4` in the selected directory and advances through
`-2`, `-3`, and later bounded numeric suffixes when required. A fail-on-conflict
policy returns a typed error. Its temporary output uses the chosen final stem,
the lowercase job UUID, and `.partial.mp4`; an existing temporary path is a
typed collision rather than an overwrite.

Only local absolute URLs are accepted. Unicode, spaces, emoji, and shell
metacharacters remain literal path characters. The final URL stays in
`OutputPlan` and is structurally absent from `TranscodeCommandRequest`; FFmpeg
receives only the job temporary and `-n`. Planning cannot reserve a final path,
so validation and atomic no-replace publication remain stage-7 responsibilities.

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
  the `.partial.mp4` name must contain the job UUID. `OutputPlanner` supplies
  conflict-free names from read-only filesystem checks. File cleanup accepts
  the plan rather than an arbitrary URL, and commit is explicitly no-replace.
  File-identity, symlink, and final publication race checks remain the
  responsibility of the stage-7 preflight and file-access adapter.
- `ProcessRequest` represents the executable, controlled environment, argument
  array, bounded event capacity, diagnostic limit, and generic cancellation
  policy as typed values. Arguments remain `[String]`; no shell command exists
  in the interface.
- `ProcessEvent` carries output chunks and a project-owned `ProcessResult` with
  a bounded diagnostic tail, never a framework process instance across
  isolation domains.
- Security-scoped access is expressed as one async operation so its lifetime can
  eventually cover probe, encode, validation, and commit.

The production runner implements pipe draining, bounded diagnostics, and direct
child cancellation. The FFprobe adapter resolves and interprets bundled probe
output. Presets, deterministic FFmpeg command construction, and safe output
naming are implemented; process-level transcode progress interpretation,
temporary validation, cleanup, and publication remain stage-7 responsibilities.

## Verification

`./Scripts/test.sh` covers the architecture scaffold; real child-process
success, failure, simultaneous pipes, bounded diagnostics, literal arguments,
cancellation, and completion; FFprobe fixture mapping and adapter boundaries;
all preset argument vectors; stream, HDR, audio, scaling, metadata, and path
behavior; and output-name collisions. `./Scripts/build.sh` remains the
canonical build check.
