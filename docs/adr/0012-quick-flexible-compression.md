# ADR 0012: Quick and flexible compression modes

- Status: Implemented
- Date: 2026-07-16
- Source of truth: [`PLAN.md`](../../PLAN.md)
- Supersedes: the single-visible-mode, fixed first-attempt audio, and compact
  availability portions of [`ADR 0011`](0011-automatic-compression.md)
- Codec and quality defaults amended by
  [`ADR 0013`](0013-main10-output-for-ten-bit-sdr.md)

## Context

The automatic policy from ADR 0011 keeps the first-run workflow simple, but it
does not let a user deliberately preserve more detail, choose a smaller output
geometry, cap frame rate, or remove the audio track before encoding. Resizer
needs that control without becoming a generic FFmpeg front end.

The mode selector and controls must remain native SwiftUI, compact, accessible,
and understandable without codec terminology. Every choice must still produce
a closed, validated `CompressionRecipe`; arbitrary flags, codecs, containers,
and output paths remain outside the UI.

## Decision

### User-visible modes

The ready screen presents a native segmented picker with two choices:

- **Quick** is the default. Its amended balanced recipe uses H.264 VideoToolbox
  quality `0.75` for ordinary sources or HEVC Main10 quality `0.70` for
  confirmed SDR sources above eight bits, at most 1920x1080 and 30 FPS, and AAC
  at 128 kbit/s when the source has audio. A single `Keep Audio` toggle may
  replace AAC with `.remove`.
- **Flexible** exposes a bounded set of product-level controls. It is not an
  arbitrary custom FFmpeg command.

Each ready job owns its own transient mode and settings draft. When Start is
pressed, that job captures its complete immutable recipe before entering the
FIFO queue. Changing the selected job or editing another draft does not alter
it, and queued or running jobs are not affected by later UI changes.

### Flexible settings

Flexible mode exposes only:

- video quality from `0.30` through `0.90`, in `0.05` UI steps;
- maximum resolution: source, 1920x1080, 1280x720, or 854x480;
- frame-rate policy: source, at most 60 FPS, at most 30 FPS, or at most 24 FPS;
- `Keep Audio`, producing AAC at 128 kbit/s when enabled and source audio exists,
  otherwise no audio stream.

Every resolution and frame-rate cap preserves aspect ratio and never increases
the source. MP4, the source-derived H.264 8-bit or HEVC Main10 policy, common
metadata, `faststart`, selected-stream mapping, validation, and publication
safety remain fixed. The UI does not expose codec, container, video bitrate,
audio bitrate, metadata policy, target size, or arbitrary FFmpeg arguments.

The read-only summary is source-aware. When a known source frame rate is at or
below the selected cap, it shows the source value as unchanged. `Up to N FPS`
is shown only when the cap reduces a higher source rate or the source rate is
unknown.

### Secondary compact attempt

`Compress More` remains available only after a Quick completed or `noBenefit`
outcome. It continues to use the fixed `compactRetry` recipe from the immutable
original. The Quick audio choice is inherited so an intentionally silent first
attempt cannot unexpectedly restore audio.

### Removing session entries

The queue trash action means **remove this entry from the current session**. It
never deletes the immutable source or a previously published output file.
Removal is allowed for ready, waiting queued, cancelled, completed, no-benefit,
and failed jobs. Probing, active queued, running, finishing, and cancelling jobs
must be cancelled first.

## Consequences

- The default path still requires no encoding knowledge.
- Flexible recipes remain typed, bounded, capability-checked, and testable.
- Retry uses the captured recipe rather than whatever controls are currently
  visible.
- Preparation admits the common video-only path; the selected immutable recipe
  receives its full capability preflight before encode. This keeps remove-audio
  available even when the source audio decoder is unsupported.
- Sources without audio disable the audio toggle and simply produce no audio
  stream; their other per-job settings remain editable.
- Domain, command, UI-model, localization, queue-removal, and accessibility
  tests must cover both modes and both audio choices.

## Alternatives considered

### Put compression controls in Settings

Rejected. The controls describe the current files and must be visible before
Start. Global preferences would make it unclear which recipe a queued job
captured.

### Expose CRF, bitrates, codecs, or raw FFmpeg flags

Rejected. VideoToolbox does not use the same quality model as software CRF
encoders, and arbitrary arguments would bypass typed validation and the product
safety boundary.

### Replace Quick with Flexible

Rejected. The zero-decision path is still Resizer's primary product promise.

## Verification

- policy tests for every flexible resolution and FPS option;
- Quick and Flexible tests with audio kept and removed;
- job tests proving the captured recipe matches its origin;
- command tests proving `.remove` emits `-an` and no audio mapping;
- feature-model tests proving settings are captured per queued job and retry;
- queue tests for removable and non-removable states;
- localization and accessibility checks for the segmented picker and controls;
- `./Scripts/build.sh`;
- `./Scripts/test.sh`.
