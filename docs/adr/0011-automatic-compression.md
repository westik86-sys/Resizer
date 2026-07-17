# ADR 0011: Automatic compression and no-benefit outcomes

> Current output encoder, pixel-format, Quick quality, and compact-retry policy
> is defined by [ADR 0016](0016-libx264-high-bit-depth-chroma.md).
> The fixed first-attempt AAC bitrate is superseded by
> [ADR 0015](0015-channel-aware-aac.md); the table below is historical.

- Status: Implemented; superseded in part by ADR 0012
- Date: 2026-07-16
- Source of truth: [`PLAN.md`](../../PLAN.md)
- Supersedes: the preset-selection, default-preset, and custom-recipe product
  portions of [`ADR 0006`](0006-presets-command-builder.md)
- Amends: the post-validation outcome branch of
  [`ADR 0007`](0007-headless-transcoding-core.md)
- Superseded in part: the single-visible-mode, fixed-first-attempt-audio, and
  initial UI decisions are superseded by
  [`ADR 0012`](0012-quick-flexible-compression.md). The `noBenefit` semantics
  remain authoritative; ADR 0012 governs audio choice, Flexible settings, and
  compact-action availability, while ADR 0016 governs current video defaults.

## Context

The existing product asks the user to choose High Quality, Balanced, or Small
File and also permits typed manual adjustments. That contract conflicts with
Resizer's simplified promise: add a video and receive the best deterministic
size/quality balance the MVP can provide without learning encoder settings.

There is no universal parameter set that is optimal for every source. The MVP
therefore needs an explicit, reviewable product policy rather than a claim of
mathematical optimality. It must also avoid publishing a technically valid
result that is the same size as, or larger than, the immutable input.

This decision changes product selection and the workflow outcome after
validation. It does not weaken the existing FFmpeg command, capability,
descriptor ownership, validation, cleanup, collision, or publication safety
boundaries.

## Decision

The initial-mode and UI statements in this section record the decision as it
was implemented before ADR 0012. They are historical where they conflict with
ADR 0012; the validation and `noBenefit` decision remains current.

### Closed compression modes

`CompressionMode` is a closed typed choice with two values:

- `automatic` is the only initial user-visible mode;
- `compactRetry` is an explicit secondary action after the first automatic
  outcome.

After a successful input probe, `AutomaticCompressionPolicy` deterministically
derives an immutable `CompressionRecipe` from the probed `MediaInfo` and the
selected mode. The first attempt always uses `automatic`:

| Mode | Video quality | Resolution | Frame rate | AAC bitrate |
|---|---:|---|---|---:|
| `automatic` | `0.65` | Maximum 1920x1080 | Maximum 30 FPS | 128,000 bit/s |
| `compactRetry` | `0.45` | Maximum 1280x720 | Maximum 24 FPS | 96,000 bit/s |

Both modes produce limited-range H.264 `yuv420p` through
`h264_videotoolbox` in MP4 with `faststart`, preserve common metadata under the
existing selected-stream policy, preserve aspect ratio, and never increase the
source resolution or frame rate. AAC is included only when the selected source
audio exists; otherwise the result has no audio.

The MVP does not expose preset selection, video quality, resolution, frame
rate, audio bitrate, metadata, or other encoding controls. It has no custom
recipe path and accepts no arbitrary FFmpeg flags. The UI may show a read-only
summary such as `MP4 · H.264 · up to 1080p · up to 30 FPS · AAC`, but normalized
quality and encoder-specific controls remain internal product policy.

`compactRetry` is not an alternative first-run preset. It always creates a new
attempt from the immutable original input, never from an automatic result. It
may be offered after either a published automatic result or an automatic
`noBenefit` outcome.

These fixed values are the starting policy for the MVP, not a target-size or
perceptual-quality guarantee. Content classification, representative sample
encodes, VMAF, and adaptive recipe search remain post-MVP decisions.

### Validate, then commit or return no benefit

FFmpeg still writes only to the job-owned anonymous staging descriptor. After
process exit, stdout/stderr EOF, a fresh probe of that exact descriptor, and
successful technical validation, the coordinator compares the validated
staging byte count with the verified input byte count.

- When staging is smaller than the input, the coordinator enters
  `finishing(.committing)` and performs the existing descriptor-source,
  no-replace `fclonefileat` publication. A successful publication produces
  `completed`.
- When staging is equal to or larger than the input, the coordinator publishes
  no final file, releases only that job's anonymous staging lease, and produces
  terminal `noBenefit`. This is a neutral successful outcome, not `failed`.

`NoBenefit` is the product outcome and `noBenefit` is its domain state. It
records the source byte count, validated candidate byte count, and elapsed time
needed for result presentation. It contains no final URL and therefore cannot
enable Open or Reveal in Finder. The candidate's bytes remain diagnostics of
the comparison, not a published artifact.

The lifecycle branch is:

```text
running
    -> finishing(validating)
        -> finishing(committing) -> completed
        -> noBenefit
```

Cancellation remains available during validation under ADR 0008. Actor
serialization determines whether cancellation or the direct terminal
`noBenefit` transition wins; a cancellation that wins first releases the same
job lease and ends in `cancelled`. Atomic publication remains the linearization
point for the completed branch.

### Preserved ADR 0006 and ADR 0007 contracts

ADR 0006 remains authoritative for all non-product-selection decisions,
including:

- normalized quality mapping to VideoToolbox `global_quality`;
- deterministic stream selection and absolute stream mapping;
- H.264/AAC codec arguments, SDR/range policy, orientation, and even,
  aspect-preserving no-upscale scaling;
- machine-readable progress, bounded diagnostics, MP4 `faststart`, and
  selected-stream metadata handling;
- ordered `[String]` arguments with no shell and no arbitrary flag escape
  hatch;
- safe output naming and the rule that FFmpeg's sole writable media target is
  child fd 3, never the input or an output pathname;
- bundled capability preflight.

ADR 0007 and ADR 0008 remain authoritative for security-scoped access,
descriptor-bound staging, exact-file validation, cancellation, cleanup, and
clone-only no-replace publication. This ADR only adds the byte comparison and
non-publication branch after technical validation.

## Alternatives considered

### Keep Balanced as the default and hide the other selectors

Rejected. A hidden default would leave presets and custom settings as product
concepts and would not define the secondary compact action or the no-benefit
outcome.

### Publish every technically valid result

Rejected. A larger copy violates the core product promise and consumes user
storage without benefit. Technical validation is necessary but not sufficient
for publication.

### Retry automatically with progressively stronger compression

Rejected for the MVP. It makes completion time unpredictable and removes the
user's deliberate choice to trade more quality for size. `compactRetry` is an
explicit secondary action.

### Estimate the result size before encoding

Rejected as a publication decision. VideoToolbox quality control does not
guarantee a byte size across different source material. Only the validated
candidate's actual byte count decides the outcome.

## Consequences

- The initial UI has one compression action and no encoder-setting decisions.
- Equal `MediaInfo` and mode values always produce the same recipe.
- Compact retry behavior is testable and cannot accidentally chain lossy
  encodes.
- A successful encode can end without a final file when it offers no size
  benefit; UI, queue, notifications, and accessibility must distinguish this
  neutral outcome from failure.
- Existing command golden tests must be rewritten around `automatic` and
  `compactRetry`, and workflow/state tests must cover both commit and
  no-benefit branches.
- The original, existing final files, and unrelated temporary paths retain all
  prior safety guarantees.

## Verification

- Automatic-policy unit tests for both modes and no-upscale/no-FPS-increase
  boundaries
- Command golden tests for `automatic` and `compactRetry`, with and without
  audio
- State-machine tests for `finishing(.validating) -> noBenefit`
- Workflow tests proving an equal/larger validated candidate is not published
  and only its anonymous lease is released
- Integration tests proving a smaller candidate still follows validation and
  no-replace publication
- `./Scripts/build.sh`
- `./Scripts/test.sh`
