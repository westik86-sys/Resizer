# ADR 0007: Headless transcoding transaction and safe publication

- Status: Accepted for implementation stage 7
- Date: 2026-07-13
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

Stages 4–6 established a safe process boundary, a bundled FFprobe adapter,
typed recipes, deterministic FFmpeg arguments, and output planning. A
successful FFmpeg exit alone is not a safe product result: the executable may
lack a required capability, progress and diagnostics must remain bounded, a
caller can race cancellation with process exit, the temporary output may be
malformed, and another process can create the chosen final name between a
read-only collision check and publication.

Stage 7 needs one non-UI transaction that preserves the immutable original,
works under App Sandbox, leaves no job-owned temporary after failure or
cancellation, and publishes only a freshly probed, recipe-compatible MP4.

## Decision

### Transaction owner

`CompressionCoordinator` owns the workflow and all lifecycle transitions. It
retains the security scopes of the selected input and output directory for the
whole operation and performs, in order:

1. probe the input and record validated `MediaInfo`;
2. record the typed configuration and plan unique output paths;
3. verify input, directory, and output-path preconditions;
4. validate the command and actual bundled FFmpeg capabilities;
5. atomically reserve and identity-seal the job `.partial.mp4`;
6. encode through a seekable descriptor for that exact inode;
7. claim `finishing(.validating)`, inspect and re-probe the temporary;
8. validate container, streams, codecs, dimensions, range, and duration;
9. atomically rename the temporary to the final path without replacement;
10. publish `completed` with the final URL, byte count, and elapsed time.

One job cannot have two workflow calls in flight. The existing coordinator
rule still allows at most one job in `running`, `finishing`, or `cancelling`;
the FIFO queue remains stage 9.

### Bundled capability preflight

`FFmpegCapabilityClient` invokes only the executable resolved from
`Bundle.main`. It queries decoders, encoders, filters, demuxers, muxers, and
input/output protocols through `ProcessRunning`. Query stdout is capped at
1 MiB and diagnostics at 128 KiB. The six queries run in parallel under one
15-second deadline. Concurrent first callers share one single-flight
discovery, a sole cancelled waiter tears it down, and only a complete
successful result is cached.

`FFmpegPreflightValidator` checks the selected source demuxer and decoders and
the recipe's required `h264_videotoolbox`, scale, MP4, file, fd, pipe, and optional
AAC/aresample capabilities. There is no `PATH`, Homebrew, codec, or executable
fallback.

When FFprobe omits numeric depth fields, known pixel-format families supply a
conservative per-component depth. An unknown-range source whose depth remains
unknown or exceeds 8-bit is rejected before encode; explicit HDR is always
rejected because this stage has no tone-mapping contract.
Non-square sample aspect ratio is likewise rejected until the scaling and
validation contracts model anamorphic display geometry.

### Process, progress, and diagnostics

`FFmpegTranscodingService` admits one active execution token per job and asks
`FFmpegCommandBuilder` for the exact argument vector. It configures a 1 MiB
diagnostic tail and the runner's maximum bounded event capacity. The service
does not accept the final URL. `SecurityScopedFileAccess` first creates the
temporary atomically with `O_EXCL`; the runner verifies its device/inode and
zero size, then binds that seekable file to stdout. FFmpeg writes MP4 to `fd:`
without reopening a pathname. The service returns the positive byte count plus
the final device/inode and timestamp seal.

`FFmpegProgressParser` incrementally parses arbitrary chunks from
`-progress pipe:2`. An incomplete line is limited to 16 KiB. Known numeric
fields are strict and nonnegative; unknown keys are ignored. Snapshots are
published only at `progress=continue` or `progress=end`, in stream order. A
complete all-`N/A` time heartbeat is skipped without failing because FFmpeg can
emit it while reconciling audio and video clocks. A successful process requires
a terminal `progress=end` record and EOF. For a nonzero process exit, the
bounded stderr diagnostic has precedence over a secondary progress-format
error.

### Cancellation linearization

Cancellation intent is recorded before process teardown. During probe or
preflight the visible phase remains non-active; the coordinator cancels its
in-flight task and waits for that operation and the security scope to settle
before transitioning to `cancelled`, and FFmpeg is never launched. During
encode the job moves from `running` to `cancelling` before
its retained transcode task is cancelled and `Transcoding.cancel` is called.
This closes the handoff race before service registration. FFmpeg is asked to
quit with `q\n`; after two
seconds the generic runner escalates through
SIGINT, SIGTERM, and SIGKILL with bounded waits while continuing to drain the
configured streams. Once cancellation wins, a later nonzero exit is returned as
`CancellationError`, not an encode failure.

The opposite boundary is also explicit: after the coordinator claims
`finishing(.validating)`, a late cancellation does not interrupt validation or
atomic commit. This prevents a normal process completion from becoming an
ambiguous half-published result.

### Validation, cleanup, and commit

The temporary must be a positive-size regular file and agree with the byte
count returned by the service. A fresh FFprobe result must contain MP4, exactly
one H.264 `yuv420p` video, normalized rotation, SDR-compatible range/depth,
only the expected optional AAC stream, no subtitle/attachment/other streams,
the recipe's no-upscale dimensions and aspect ratio, and a duration within the
bounded tolerance.

`SecurityScopedFileAccess` performs terminal-entry checks with `lstat`, rejects
symlinks and unsupported types, and compares device/inode identity so a hard
link cannot alias the original. The validator carries an inode, size,
modification-time, and status-change-time seal; metadata must match after the
probe and again immediately before commit, and the published inode is checked.
It commits with
`renameatx_np(..., RENAME_EXCL)`. This closes the final-name collision race and
never replaces an existing entry. Failure and cancellation call `unlink` only
when the regular file still has the initial reservation identity or the final
transcoder seal. A replacement inode is preserved; a mutation of the same
owned inode can still be removed after validation fails. Atomic reservation
means a preflight race becomes a collision, while the inherited descriptor
means FFmpeg cannot reopen and overwrite a replacement pathname. Cleanup never
uses a directory scan, prefix, glob, caller-provided arbitrary URL, or a
missing identity seal.

## Alternatives considered

### Trust a zero FFmpeg exit and rename immediately

Rejected. A process can exit zero while producing a stream layout, codec,
duration, orientation, or file that violates the product contract.

### Write FFmpeg output directly to the final URL

Rejected. It exposes incomplete data, cannot validate before publication, and
cannot safely resolve a collision race without replacing user data.

### Use `FileManager.moveItem` after a separate existence check

Rejected. The check and move are not one no-replace filesystem operation.
`RENAME_EXCL` gives the required atomic publication rule on supported macOS.

### Treat every cancellation/process-exit race as an encode failure

Rejected. It makes the visible result scheduler-dependent and can report an
expected graceful stop as a product error. Intent and finishing claim define
the two deterministic race winners.

## Consequences

- Stage 8 can drive one complete compression operation without owning any
  `Process`, pipe, filesystem publication, or cancellation logic.
- Capability discovery adds startup work once per service instance, then is
  cached; a failed discovery is retryable rather than cached.
- The final filename is still optimistic during planning, but publication is
  collision-safe. A late collision becomes a typed commit failure.
- Cleanup is deliberately narrow. An unrelated stale file is never removed,
  even if its name resembles a Resizer temporary.
- The stage validates the H.264 SDR MVP only; HDR tone mapping, HEVC, arbitrary
  flags, target-size encoding, queueing, and retry UI remain out of scope.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Application/CompressionWorkflowTests.swift`
- `ResizerTests/Infrastructure/FFmpegCapabilitiesTests.swift`
- `ResizerTests/Infrastructure/FFmpegProgressParserTests.swift`
- `ResizerTests/Infrastructure/FFmpegTranscodingServiceTests.swift`
- `ResizerTests/Infrastructure/SecurityScopedFileAccessTests.swift`
- `ResizerTests/Infrastructure/TranscodeOutputValidatorTests.swift`
- `ResizerTests/Integration/HeadlessTranscodingIntegrationTests.swift`

The integration fixture is
`ResizerTests/Fixtures/Media/short-h264-aac.mp4`, with SHA-256
`d36f4bd50eb9294bef46aec9de1b6182a32fc7980ad81b070b7b9ce44d91f1c1`.
It is a locally generated three-second H.264/yuv420p plus mono AAC artifact,
not third-party media. Running the test requires neither network access nor a
system/Homebrew FFmpeg installation.
