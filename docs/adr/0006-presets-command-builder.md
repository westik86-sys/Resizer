# ADR 0006: Preset recipes, FFmpeg command construction, and output planning

> Ordinary H.264 encoding, rate control, and licensing/source-distribution
> details are superseded by [ADR 0014](0014-libx264-gpl-toolchain.md).

- Status: Accepted for implementation stage 6; preset selection, default preset,
  and custom-recipe product decisions superseded by
  [`ADR 0011`](0011-automatic-compression.md); input capability profile amended
  by [`ADR 0009`](0009-hevc-input.md)
- Date: 2026-07-13
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

After probing produces validated `MediaInfo`, Resizer needs one deterministic
translation from product settings to FFmpeg arguments and one safe translation
from an input name to temporary and final output paths. This boundary must keep
the product preset-led: callers provide typed values, not arbitrary FFmpeg
flags, and FFmpeg must never receive the final output URL.

The public build is Universal 2 and uses the bundled LGPL-only FFmpeg profile.
Consequently, the quality control must work with `h264_videotoolbox` on both
Apple Silicon and Intel. The command must also make stream selection,
orientation, scaling, metadata, audio absence, and unsupported HDR behavior
explicit rather than relying on FFmpeg defaults.

## Decision

### Preset contract

`CompressionRecipe(preset:)` is the only factory for built-in presets. It
produces MP4 with `h264_videotoolbox`, preserves the selected common metadata,
and records the preset in `RecipeOrigin`. The fixed values are:

| Preset | Video quality | Resolution | Frame rate | AAC bitrate | Metadata |
|---|---:|---|---|---:|---|
| High Quality | `0.85` | Original | Original | 192,000 bit/s | Preserve common |
| Balanced | `0.65` | Maximum 1920x1080 | Maximum 30 fps | 128,000 bit/s | Preserve common |
| Small File | `0.45` | Maximum 1280x720 | Maximum 24 fps | 96,000 bit/s | Preserve common |

Balanced is the default. Quality decreases monotonically across the three
presets, but it remains a quality request rather than a target-size promise.
Changing an individual setting produces a typed custom recipe; it does not
allow a free-form argument string.

Map normalized `VideoQuality` to VideoToolbox's integer
`-global_quality:v:0` range by rounding the percentage and clamping it to
`1...100`. In particular, domain value `0` becomes `1` and `1` becomes `100`.
Do not use CRF: it is not the selected VideoToolbox rate-control model and would
suggest the non-selected libx264 workflow. Do not use `-q:v`/qscale either;
the pinned FFmpeg VideoToolbox implementation rejects qscale on Intel, which
would violate the Universal 2 contract.

### Deterministic stream and codec arguments

`FFmpegCommandBuilder` is a stateless `Sendable` implementation of
`CommandBuilding` and returns only `[String]`. It validates local absolute input
and temporary URLs before constructing arguments.

Select exactly one real video stream. Ignore attached pictures, prefer the
lowest-index default video, and otherwise use the lowest-index video. Select
audio with the same default-then-lowest-index rule. Map selected streams by
their absolute input indices (`0:<index>`) so an attached picture or an earlier
unselected stream cannot shift a type-relative map. Explicit `-sn` and `-dn`
drop subtitle and data streams; multi-audio and subtitle management remain
outside the MVP.

Preserved video metadata may contain a `timecode` tag. In its automatic mode,
the MP4 muxer can turn that tag back into a new `tmcd` data stream even when
`-dn` excluded every input data stream. Every MP4 command therefore emits
`-write_tmcd 0`. Timecode tracks are intentionally not preserved; the output
validator remains strict and rejects any subtitle, attachment, or data stream.

When the recipe requests AAC and a selected audio stream exists, map only that
stream and encode it at the typed bitrate. If probe data contains no audio,
emit `-an` and continue successfully. The explicit remove-audio policy also
emits `-an` and maps no audio or audio metadata.

Output video is explicitly `h264_videotoolbox` with `yuv420p`. The builder
adds `-fpsmax:v:0` only for a capped frame-rate policy; original FPS omits the
option. This expresses a maximum and avoids raising a lower source frame rate
as a fixed `-r` could.

### Orientation, SDR policy, and scaling

Enable FFmpeg autorotation and clear the output video stream's rotation tag
with `rotate=0` after transforming the frames. This avoids displaying an
already rotated result a second time.

The stage-6 path is an SDR H.264 compatibility path, not tone mapping. Reject a
selected stream classified as HDR. Also reject an unknown-range stream unless
its component depth is proven to be at most 8-bit because it may be unlabelled
HDR. An explicitly classified SDR stream,
including an explicitly SDR 10-bit source, may be converted to 8-bit
`yuv420p`; later integration validation must prove the supported source
decoders and resulting playback.

Always use a typed scale filter. Original resolution means no configured
maximum, but dimensions are normalized to positive even values for H.264
compatibility, normally rounding an odd edge down by one pixel. A
maximum-resolution recipe uses a dynamic expression
based on `iw` and `ih`, so the same command handles portrait and landscape
after autorotation. Each target dimension is bounded by the corresponding
input dimension, aspect ratio is preserved, upscaling is prevented, the result
is divisible by two, and sample aspect ratio is reset. Lanczos is the fixed
scaling algorithm.

### Progress, container, and metadata

Every command includes machine-readable progress with a 0.25-second update
period:

```text
-stats_period 0.25 -nostats -progress pipe:1
```

The builder does not add `-nostdin`, because the headless transcoder will use
the process runner's graceful `q\n` cancellation before signal fallbacks. The
output container is explicitly MP4, and `-movflags +faststart` prepares the
validated result for ordinary playback and sharing. Progress is emitted only on
stdout; stderr is reserved for bounded diagnostics. Stage 7 binds the retained
anonymous `O_RDWR` temporary to child fd 3, so the output target is `fd:3`
rather than stdout or a pathname. The bundled `fd:` protocol keeps per-context
logical offsets and uses positioned I/O for seekable descriptors, allowing the
MP4 muxer's `+faststart` reopen to use that same file safely.

Preserve-common metadata has a deliberately narrow stream-selection meaning:

- copy global metadata from input 0;
- copy metadata only from the selected video and included audio streams;
- preserve chapters;
- clear the stale rotation tag after autorotation.
- disable MP4 `tmcd` generation from copied timecode metadata.

Remove metadata disables global, selected-stream, and chapter mappings. It
still writes `rotate=0` as the orientation-safety override. Unselected stream
metadata is never copied. The MP4 muxer may omit unsupported source keys; this
stage does not introduce arbitrary metadata editing or a key-by-key UI.

### Output naming and publication boundary

`OutputPlanner` derives the base stem from the input stem plus the validated
policy suffix, normally producing `source-compressed.mp4`. Under
`appendNumericSuffix`, a collision selects `source-compressed-2.mp4`, then
`-3`, and so on up to the bounded search limit. Under `fail`, the first
collision returns a typed error.

The temporary name is derived only after the final stem is selected and has
this form:

```text
source-compressed[-N].<lowercase-job-uuid>.partial.mp4
```

It is in the selected output directory, preserves the real `.mp4` extension,
and must not already exist. A temporary collision is an error rather than an
overwrite or broad cleanup opportunity. Unicode, whitespace, emoji, and shell
metacharacters remain literal filename characters because neither planner nor
builder invokes a shell.

The final URL is retained in `OutputPlan` but excluded from
`TranscodeCommandRequest`, so it cannot enter the FFmpeg argument vector. The
builder accepts only the job-owned `.partial.mp4`, rejects an input/temp alias,
and emits no output pathname. Stage 7 atomically creates that path with
`O_EXCL | O_RDWR`, immediately unlinks it, retains its exact descriptor, and
gives it to FFmpeg as child fd 3. FFprobe validates that same descriptor, and
`fclonefileat` publishes it with no replacement under the contract described in
[ADR 0007](0007-headless-transcoding-core.md); planning does not reserve the
final name against a later filesystem race.

## Capability boundary for stage 7

Stage-6 golden tests prove deterministic construction, not that every probed
input is decodable by the bundled binary. The current minimal toolchain profile
contains native H.264, HEVC, and AAC decoders, while FFprobe can describe other
MOV/MP4 streams, including AV1/VP9 video or non-AAC audio. A valid recipe and
command therefore do not by themselves prove that the selected input codecs
are available.

Every video recipe converts the filter output to limited (`tv`) range and also
sets the encoder's output range explicitly. Full-range 8-bit SDR camera input
such as `yuvj420p` therefore becomes the validator's deterministic limited-range
H.264 `yuv420p` compatibility output instead of merely relabelling full-range
samples.

Before launching FFmpeg, the stage-7 preflight compares selected input and
required output features with the cached capabilities of the actual bundled
build. Missing decoder, encoder, filter, muxer, or protocol support returns
a typed unavailable-capability failure. Expanding the toolchain profile is a
separate reproducibility and licensing change; falling back to Homebrew,
`PATH`, or another codec is not permitted.

## Alternatives considered

### Map all streams and let FFmpeg choose defaults

Rejected because attached pictures, multiple audio tracks, subtitles, and data
would make results input-dependent and could require unavailable encoders. The
MVP deliberately selects one video and at most one audio stream.

### Encode directly to the final name

Rejected because successful process exit is not sufficient validation and
because a collision race could replace user data. FFmpeg writes only the
anonymous job file through `fd:3`; validation and no-replace publication
are separate stage-7 operations.

### Fixed landscape scale dimensions

Rejected because they constrain portrait media by the wrong edge and may
upscale smaller sources. The dynamic filter uses the post-autorotation input
orientation and input-bounded expressions.

## Consequences

- Recipe behavior and argument ordering are stable, reviewable golden-test
  contracts rather than UI conventions.
- Originals and final outputs remain outside FFmpeg's writable target. FFmpeg
  receives only child fd 3 for the anonymous temporary, never either output
  pathname.
- HDR and uncertain high-bit-depth inputs fail closed until a separately
  designed tone-mapping/HDR workflow exists.
- Original resolution may lose one pixel on an odd edge to satisfy the even
  H.264 output invariant.
- Metadata preservation applies only to the chosen MVP streams and chapters,
  not every input stream or every source-specific key.
- Final collision safety still depends on stage 7 performing validation and an
  exact no-replace publication after encoding. Publication requires a
  clone-capable same-volume filesystem; preflight rejects an unsupported output
  volume before encoding.
- Capability-aware preflight remains mandatory even though recipes and command
  syntax are valid.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Domain/AutomaticCompressionPolicyTests.swift`
- `ResizerTests/Infrastructure/FFmpegCommandBuilderTests.swift`
- `ResizerTests/Infrastructure/OutputPlannerTests.swift`
