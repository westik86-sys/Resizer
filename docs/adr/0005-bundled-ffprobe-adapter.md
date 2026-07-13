# ADR 0005: Bundled FFprobe adapter and metadata mapping

- Status: Accepted for implementation stage 5
- Date: 2026-07-13

## Context

The headless compression workflow needs a stable `MediaInfo` value before it
can select streams, build an FFmpeg recipe, report source metrics, or validate
an encoded result. FFprobe JSON is an external transport format: fields may be
absent, new fields appear between releases, and many numeric values are emitted
as strings. Treating that JSON as the domain model would couple later stages to
tool-specific spelling and sentinel values.

The adapter must also preserve the stage-4 process guarantees. Probe output is
machine-readable and cannot be silently truncated, cancellation cannot leave a
direct child behind, and production must never discover an incompatible system
or Homebrew executable.

## Decision

Implement a stateless, `Sendable` `FFprobeClient` behind `MediaProbing`. The
production factory resolves only the `ffprobe` auxiliary executable in
`Bundle.main`, resolves symlinks, verifies that the resulting regular executable
remains inside the resolved bundle, and has no `PATH` fallback. Tests inject
both an absolute executable URL and a `ProcessRunning` implementation.

Launch through `ProcessRequest` with the exact logical arguments:

```text
-v error -print_format json -show_format -show_streams -show_chapters INPUT
```

Collect stdout chunks up to an 8 MiB default limit. Keep stderr ownership in
`ProcessRunner`, which already returns a bounded diagnostic tail. Require one
matching terminal result, distinguish normal zero exit from nonzero exit or
signal, and expose typed client failures. On overflow or task cancellation,
request process teardown and await it from an uncancelled cleanup task before
returning.

Decode into FFprobe-only DTOs before mapping into Domain. Flexible numeric DTO
scalars accept strings and JSON numbers, require complete numeric-string
consumption, and distinguish the `N/A` sentinel from corrupt or overflowing
values. Missing root arrays and format data are valid, and unknown JSON keys are
ignored. Mapping applies these rules:

- split comma-separated format names and trim whitespace;
- convert nonnegative duration to rounded integer microseconds;
- default missing size to zero and keep missing bitrate optional;
- retain every video, audio, subtitle, and other stream in source order;
- require unique nonnegative stream indices;
- prefer valid `avg_frame_rate`, then fall back to `r_frame_rate`;
- prefer Display Matrix rotation over the legacy `rotate` tag;
- preserve raw color fields and classify only known transfer functions as HDR
  or SDR;
- allow media with no video or no audio;
- decode chapters but leave chapter modeling to a later domain requirement.

Malformed JSON and structurally invalid mapped metadata remain distinct typed
parser errors.

## Consequences

- Later recipe and headless-core stages consume validated `MediaInfo` rather
  than FFprobe dictionaries or sentinel strings.
- New unknown FFprobe fields do not require releases, while invalid required
  identity such as a missing stream index fails explicitly.
- Production behavior is reproducible with the bundled FFmpeg toolchain and
  cannot change because of a user's local package installation.
- The adapter does not acquire security-scoped access itself; the future
  coordinator owns an access lifetime spanning probe, encode, validation, and
  commit.
- Fixture tests exercise metadata variation without real media or external
  tools; the existing signed sandbox spike remains the real bundled-tool proof.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Infrastructure/FFprobeParserTests.swift`
- `ResizerTests/Infrastructure/FFprobeClientTests.swift`
- `ResizerTests/Fixtures/FFprobe/`
