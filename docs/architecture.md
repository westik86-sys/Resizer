# Resizer architecture

This document describes the production architecture through stage 10: domain
and service contracts, process and FFmpeg boundaries, the transactional
workflow, the session FIFO queue, the SwiftUI feature model, and hardening for
shutdown, publication, diagnostics, accessibility, and localization.

## Dependency direction

```text
SwiftUI views
    -> @MainActor CompressionFeatureModel
        -> CompressionCoordinator actor
            -> MediaProbing
            -> Transcoding
            -> OutputPlanning
            -> FileAccessing
            -> TranscodeOutputValidating

FFmpegTranscodingService
    -> CommandBuilding
        -> FFmpegCommandBuilder
    -> FFmpegCapabilityProviding
        -> FFmpegCapabilityClient
    -> ProcessRunning
        -> ProcessRunner actor
            -> direct child executable
            -> concurrent stdout/stderr drains
            -> exact inherited output descriptor as child fd 3

SecurityScopedFileAccess
    -> retained user-selected URL scopes
    -> anonymous O_RDWR staging file plus retained directory descriptor
    -> exact descriptor metadata and file-type checks
    -> no-replace fclonefileat publication

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
execution, probing, command construction, capability discovery, transcoding,
validation, output planning, file publication, the FIFO coordinator, and the
product feature model.

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

`ResizerApp` displays the production `CompressionFeatureModel` created by the
composition root. `ApplicationLifecycleDelegate` delays normal termination
until that model has shut down the coordinator and all active workflows.

## Process execution contract

`ProcessRunner` is an actor-owned, generic implementation of `ProcessRunning`.
It launches an absolute executable URL directly with a `[String]` argument list
and an exact controlled environment. It never constructs a shell command and
does not depend on `PATH`. Ordinary requests use `Foundation.Process`;
requests that inherit an exact file descriptor are routed to the actor-owned
`posix_spawn` path because `Foundation.Process` does not preserve arbitrary
extra child descriptors.

Every start uses a fresh, one-shot `ProcessExecutionID`; cancellation becomes
valid after `start` returns its stream, and IDs are never reused. The actors own
the child-process handle or PID, configured descriptors, stream continuation,
diagnostic tail, and cancellation state. Every start also receives a private
generation token, so a late internal callback cannot be confused with newer
actor state. Independent workers receive only streamed stdout/stderr handles
and return `Data` chunks, the public ID, and that token to the actor. Framework
process instances and raw mutable execution state never cross the isolation
boundary.

Completion is a three-way barrier:

```text
process terminated
        + stdout EOF
        + stderr EOF
        -> one terminal ProcessResult
        -> continuation finishes once
```

A request may additionally inherit one already-open regular-file descriptor.
The descriptor runner verifies it with `fstat`, duplicates that exact open file
description to the declared child descriptor, and closes unrelated descriptors
in the spawned child. Stage 7 uses child fd 3 for the anonymous `O_RDWR` MP4
temporary. stdin remains available for graceful cancellation, stdout remains a
pipe for machine-readable progress or FFprobe JSON, and stderr remains a
separate diagnostic pipe. The same three-way completion barrier therefore
applies to both launch paths.

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

An input probe starts a fresh process with one literal argument array:

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

Validation does not reopen the planned temporary pathname. The coordinator
passes the retained anonymous reservation to `FFprobeClient`, which maps that
exact open file to child fd 3 and uses `fd:3` as the input argument. FFprobe JSON
still arrives on stdout and diagnostics stay on stderr. This proves the media
contract for the same file description that FFmpeg filled, even if another
entry later appears at the old `.partial.mp4` name.

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

Video output is H.264 VideoToolbox in limited-range `yuv420p`. The scale filter
performs the range conversion for full-range 8-bit SDR input, and matching
encoder metadata is explicit. Normalized quality maps to VideoToolbox
`global_quality` `1...100`; CRF and qscale are intentionally not used. A capped
frame-rate policy emits `fpsmax`, while original FPS adds no rate override.
Scaling is orientation-aware, preserves aspect ratio, never upscales, and
produces even dimensions. Autorotation is applied to pixels and the stale output
rotation tag is cleared. FFprobe recovers component depth from
known planar, packed, and float pixel-format names when numeric fields are
missing. Known HDR and unknown-range video whose depth is either above 8-bit or
still unknown fail closed because this path does not implement tone mapping.
FFprobe also retains sample aspect ratio; non-square (anamorphic) source pixels
fail preflight until display-geometry-aware scaling is implemented.

Every command sends bounded machine-readable progress to stdout with
`-progress pipe:1` and writes seekable MP4 to `fd:3` on a separately inherited
`O_RDWR` descriptor. stderr contains diagnostics only. The bundled FFmpeg `fd:`
protocol keeps an independent logical offset per protocol context and uses
positioned I/O for a seekable descriptor, so MP4 `+faststart` can reopen the
output internally without sharing or corrupting offsets. stdin remains
available for stage-7 graceful `q\n` cancellation. Preserve metadata maps only
global data, selected stream data, and chapters; remove metadata disables those
input mappings. The full argument and preset decision is recorded in
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
receives neither the final nor temporary pathname as an output argument. The
workflow atomically reserves the planned temporary and binds its descriptor to
FFmpeg. The directory entry is unlinked immediately after successful
reservation, while the open file and directory descriptors remain held through
encode, validation, and publication. Planning cannot reserve a final path, so
validation and no-replace publication remain distinct steps.

## Headless transcoding workflow

`CompressionCoordinator.process(jobID:configuration:)` owns the complete
non-UI transaction. It keeps security-scoped access to the selected input and
output directory alive across this ordered sequence:

```text
probe input
    -> record MediaInfo and configuration
    -> plan unique temporary and final paths
    -> file and bundled-capability preflight
    -> verify clone publication on the held output-directory fd
    -> atomically create, identity-check, unlink, and retain O_RDWR staging
    -> run FFmpeg with that exact file as child fd 3
    -> claim finishing(validating)
    -> inspect and re-probe that same child-fd-3 file
    -> validate the encoded media contract
    -> no-replace fclonefileat publication to final
    -> completed result
```

The workflow never gives FFmpeg the final URL. Before launch it verifies a
regular, non-empty input, a real output directory, absent staging and final
entries, and clone publication support on the opened output-directory
descriptor. It creates the staging file with
`O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW`, verifies its descriptor/name
identity, unlinks the name immediately, and retains both descriptors as a job
lease. Volumes without clone support fail before encode. `fclonefileat`
publishes the exact anonymous descriptor and refuses an existing final entry.
Failures before commit and cancellations release only that lease; cleanup never
accepts an arbitrary URL or uses a wildcard or directory scan. A second
concurrent workflow for the same job is rejected, and the coordinator
continues to enforce one running/finishing/cancelling job.

`FFmpegCapabilityClient` queries the actual bundled executable for decoders,
encoders, filters, demuxers, muxers, and protocols. Discovery is single-flight
for concurrent callers, runs all six queries in parallel, has a 15-second
overall deadline, and is cached only after a complete successful result. A
sole cancelled waiter tears down discovery; cancellation of one of several
waiters does not poison their shared task. Each query has bounded stdout and
diagnostics. `FFmpegPreflightValidator` then requires the selected input
demuxer and decoder. The bundled profile provides native H.264, HEVC, and AAC
decoders; output preflight still requires `h264_videotoolbox`, MP4, scale,
AAC/aresample when audio is selected, and the file/fd/pipe protocols used by
the command. Missing capabilities fail before the job enters `running`.

`FFmpegTranscodingService` owns one active execution identity per job. It uses
the command builder and process runner, retains an additional narrow input and
output-directory scope, drains the runner stream through EOF, and reports a
typed nonzero exit with the runner's bounded stderr tail. Its progress parser
accepts arbitrary stdout chunks from `-progress pipe:1`, caps an incomplete line,
requires record terminators and `progress=end` on success, and publishes
processed time, fraction, frame rate, speed, and output byte count in order.
Unknown progress keys are ignored so additions by FFmpeg do not break the
contract. A complete heartbeat whose time fields are all `N/A` is accepted but
does not publish a snapshot; real FFmpeg emits this while reconciling audio and
video clocks.

Cancellation is an explicit race policy. During probe or preflight the
coordinator records intent while retaining the current non-active phase, lets
the coordinator-owned in-flight task cancel and the security-scope lifetime
settle, then publishes `cancelled`; FFmpeg is never launched.
During encode it moves the job to `cancelling` before asking the service to
stop. The coordinator also cancels its retained transcode task, so cancellation
cannot be lost if the service has not registered the execution yet. The process policy
sends bounded `q\n`, waits two seconds, then lets `ProcessRunner` escalate
through SIGINT, SIGTERM, and SIGKILL while still awaiting process termination
and configured stream completion. Once cancellation has won, a later nonzero
exit cannot become an ordinary failure. Validation and commit also register
their in-flight operations. Cancellation before publication moves the job to
`cancelling` and cleans its staging file; once the atomic publication syscall
has succeeded, completion wins a simultaneous late cancellation.

## Output validation and publication

`TranscodeOutputValidator` accepts only the recipe's MP4/H.264 compatibility
result: one non-attached H.264 `yuv420p` video stream, no subtitles,
attachments, or other streams, normalized rotation, SDR-compatible depth and
range, the recipe's AAC-or-no-audio policy, expected no-upscale dimensions and
aspect ratio, and duration within a bounded tolerance. Validation uses a fresh
probe of the same retained staging descriptor after the process and both-pipe
completion barrier. The output probe receives that exact file as child fd 3;
it does not resolve or reopen the planned temporary pathname.

`SecurityScopedFileAccess` rejects terminal symlinks and unsupported file types
during input and directory checks, then uses `fstat` for all staging metadata.
Immediately before unlink it compares
`fstatat(..., AT_SYMLINK_NOFOLLOW)` with the held descriptor and requires one
link; after unlink it requires the same inode with zero links before returning
the lease. It compares device/inode identity to reject an input/temp hard-link alias and
checks size and timestamps before and after FFprobe. Clone publication passes
the exact anonymous source fd, retained directory fd, and final basename to
`fclonefileat`, which refuses an existing destination. On failure or
cancellation, cleanup closes only the anonymous lease; a later replacement at
the planned temporary pathname is preserved.

A volume without clone support returns a typed reservation error before FFmpeg
starts. There is no named, copy-overwrite, or check-then-move fallback. No final
output is claimed, no existing destination is replaced, and the immutable input
is never opened for writing.

Darwin has no conditional unlink-by-inode operation. The staging identity check
and unlink are therefore a synchronous best-effort boundary against accidental
replacement, with no suspension between them and an unpredictable per-job
name. A hostile process running as the same macOS user and able to write to the
selected directory is outside that boundary: it could race the tiny window and
cause its replacement entry to be unlinked. The zero-link descriptor check and
`fclonefileat` still bind validation and final publication to Resizer's retained
file, so the race cannot substitute encoded content or replace the immutable
input or an existing final output.

## Session queue and product UI

`JobQueueCoordinator` owns ordered job identity, the one active workflow, and a
single FIFO drain task. Imports may probe concurrently, but queue admission
order defines encode order. One job cannot be active twice; cancel, retry,
remove, and reorder are actor-serialized. A failed or cancelled job releases
the active slot and does not block the next waiter. Monotonic snapshot revisions
prevent a delayed observation from replacing newer UI state.

`CompressionFeatureModel` is `MainActor`-isolated and consumes immutable
snapshots. It owns only transient presentation state: selection, import and
button activity, session defaults, validation messages, and smoothed ETA.
SwiftUI views never launch or retain a process. Every queued attempt captures a
validated immutable `JobConfiguration`; later settings edits affect only future
admissions and retries.

Typed `FailureReason` values provide actionable primary messages. Process exit
status is confined to `DiagnosticReportBuilder`, which adds app/tool versions,
license profile, stage, reason, truncation state, and a bounded sanitized tail.
Selected paths and filenames are redacted before either display or pasteboard
copy. The string catalog contains English and Russian values and plural rules.
Accessibility focus moves to validation, failure, and success headings; controls
and metrics expose explicit labels, values, and keyboard actions.

Normal app termination calls `CompressionFeatureModel.shutdown()`. The queue
stops accepting work, cancels its driver and every workflow, then waits for its
workflow set and child-process completion barriers to drain before AppKit is
allowed to terminate.

## Job state contract

`JobState` is the single lifecycle source of truth. Progress updates replace the
associated value of `running` or `cancelling`; they are not lifecycle
self-transitions.

| Current state | Allowed next state |
| --- | --- |
| `draft` | `probing` |
| `probing` | `ready`, `cancelled`, `failed(probe)` |
| `ready` | `queued`, `cancelled` |
| `queued` | `running`, `cancelled`, `failed(preflight)` |
| `running` | `finishing(validating)`, `cancelling`, `failed(encode)` |
| `finishing(validating)` | `finishing(committing)`, `cancelling`, `failed(validate)` |
| `finishing(committing)` | `completed`, `cancelling`, `failed(commit)` |
| `cancelling` | `cancelled`, `completed`, `failed(file-system only)` |
| `cancelled` | `ready`, `probing` |
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
- `queued` and post-probe processing/final states require both media information
  and a typed configuration; cancellation from `probing` or pre-configuration
  `ready` is the explicit exception;
- the coordinator permits at most one `running`, `finishing`, or `cancelling`
  job at a time;
- once cancellation wins the transition to `cancelling`, ordinary workflow
  failures are rejected; an exact-cleanup filesystem failure may replace it,
  while `completed` is allowed only when atomic publication already won;
- retrying a failed probe clears stale media and configuration before probing
  again;
- a completed result must be a non-empty local file and cannot directly resolve
  to the immutable input path.

Pre-run cancellation intent does not mutate the visible phase immediately.
Only after an in-flight probe or preflight has been asked to cancel and the
security-scope lifetime has settled does the coordinator take the direct
transition to `cancelled`. A probe cancelled before metadata exists retries
through `probing`; later cancellation can reuse `ready`.

## Safe service contracts

- `TranscodeRequest` can be created only from a validated `OutputPlan`, and
  `TranscodeCommandRequest` can be created only from that transcode request.
  The final URL never enters the FFmpeg argument vector. A reservation carries
  the retained exact file and directory descriptor lease; a `TranscodeResult`
  must include a positive byte count for that reservation and cannot substitute
  another URL or descriptor.
- `OutputPlan` binds the job, input, temporary, and final URLs and rejects direct
  path aliases. Both outputs must be MP4 files in the selected directory, and
  the `.partial.mp4` name must contain the job UUID. `OutputPlanner` supplies
  conflict-free names from read-only filesystem checks. File cleanup and commit
  accept the exact reservation rather than an arbitrary URL; commit is
  explicitly no-replace. `SecurityScopedFileAccess` implements descriptor
  identity, symlink, anonymous cleanup, and final-publication checks.
- `ProcessRequest` represents the executable, controlled environment, argument
  array, bounded event capacity, diagnostic limit, generic cancellation policy,
  and optional exact inherited descriptor as typed values. Arguments remain
  `[String]`; no shell command exists in the interface.
- `ProcessEvent` carries output chunks and a project-owned `ProcessResult` with
  a bounded diagnostic tail, never a framework process instance across
  isolation domains.
- Security-scoped access is expressed as one async operation so its lifetime can
  cover probe, encode, validation, and commit.

The production runner implements pipe draining, bounded diagnostics, and direct
child cancellation. The FFprobe adapter resolves and interprets bundled probe
output. Presets, deterministic FFmpeg command construction, safe output naming,
capability-aware preflight, process-level progress, cancellation, temporary
validation, exact cleanup, and no-replace publication are implemented.

## Verification

`./Scripts/test.sh` covers the architecture scaffold; real child-process
success, failure, simultaneous pipes, bounded diagnostics, literal arguments,
cancellation, and completion; FFprobe fixture mapping and adapter boundaries;
all preset argument vectors; stream, HDR, audio, scaling, metadata, and path
behavior; output-name collisions; capability discovery; incremental progress;
headless success/failure/cancellation races; output validation; and guarded
publication and cleanup. Signed targeted integration tests run the bundled
probe → transcode → probe transaction on deterministic H.264/AAC and HEVC/AAC
MP4 fixtures and verify that both produce the same H.264/AAC compatibility
output without modifying the input.
`./Scripts/build.sh` remains the canonical build check.
