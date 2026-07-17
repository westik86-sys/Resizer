# ADR 0016: Software H.264 for all supported SDR output

- Status: Accepted
- Date: 2026-07-17
- Source of truth: [`PLAN.md`](../../PLAN.md)
- Supersedes: the automatic HEVC Main10 output policy in
  [`ADR 0013`](0013-main10-output-for-ten-bit-sdr.md), the Quick CRF 24 and
  8-bit-only libx264 portions of
  [`ADR 0014`](0014-libx264-gpl-toolchain.md), and the corresponding codec,
  pixel-format, and compact-retry defaults in
  [`ADR 0012`](0012-quick-flexible-compression.md)

## Context

A 1080x1920, 24 FPS, 10-bit 4:4:4 SDR source exposed a large efficiency gap
between Resizer's automatic HEVC VideoToolbox path and CompressO's software
libx264 path. Resizer produced about 38.6 MB at roughly 4.06 Mbit/s, while
libx264 CRF 24/preset medium produced about 9.8 MB at roughly 0.93 Mbit/s with
high perceptual quality. The hardware encode used a short GOP and no B-frames;
software x264 used longer scene-aware prediction and B-frames.

The existing bundled x264 was restricted to 8-bit 4:2:0, so merely selecting
libx264 for the source would have discarded both bit depth and 4:4:4 chroma.
Controlled comparison selected CRF 22 as the balanced Quick default: it keeps
more quality margin than CRF 24 while remaining substantially smaller than the
old automatic result.

## Decision

- Every supported SDR Quick, Flexible, and `compactRetry` output uses software
  libx264. HEVC remains a supported input decoder, but `hevc_videotoolbox` is
  removed from the minimal bundled output profile and no recipe selects it.
- Quick uses CRF 22 and preset `medium`. Flexible retains its existing closed
  quality range and mapping
  `CRF = 36 - floor(12 × qualityPercent / 100)`, yielding CRF 33...26.
  `compactRetry` uses CRF 31.
- Sources at or below 8-bit produce limited-range `yuv420p` for broad H.264
  compatibility. Confirmed SDR sources above 8-bit produce 10-bit output and
  preserve supported source chroma as `yuv420p10le`, `yuv422p10le`, or
  `yuv444p10le`. Unsupported or unknown high-bit-depth chroma fails closed.
- The pinned x264 source and GPL 2.0-or-later license profile do not change.
  Both architectures build that source with `--bit-depth=all` and
  `--chroma-format=all`; FFmpeg remains `--enable-gpl` and continues to exclude
  `--enable-version3`, `--enable-nonfree`, and libx265.
- Explicit HDR is always rejected because this decision does not add tone
  mapping. Unknown-range input is rejected when its depth is unknown or above
  8-bit; proven <=8-bit input may be converted to the explicit limited-range
  output contract. Resolution, FPS, audio, metadata, immutable-input,
  validation, and safe-publication policies remain unchanged.

## Compatibility and distribution consequences

Ten-bit H.264 4:2:0, 4:2:2, and 4:4:4 naturally select High 10, High 4:2:2,
and High 4:4:4 Predictive profiles. These profiles preserve source precision
and chroma, but hardware decoders, browsers, messaging services, and upload
pipelines support them less consistently than ordinary 8-bit 4:2:0 H.264.
Any release claim naming an external playback or upload target as compatible
with these high-bit-depth profiles requires a recorded smoke test for that
exact target. The UI must not promise universal compatibility.

All output encoding is CPU-bound and may be slower and more energy-intensive
than VideoToolbox, particularly on Intel. The trade-off is deterministic,
content-aware rate control and substantially better observed quality/size on
the motivating material.

The licensing decision remains GPL 2.0-or-later. Removing a system encoder and
expanding x264's compiled pixel formats does not introduce a new dependency or
change source-distribution obligations. Releases must still include the exact
Resizer, FFmpeg, and x264 corresponding source, checksums, build instructions,
patches, configuration/capability reports, licenses, and notices.

## Build and verification contract

- Rebuild both x264 architecture slices from the pinned archive with all bit
  depths and chroma formats, then rebuild and audit the Universal 2 FFmpeg and
  FFprobe tools. Generated configuration evidence must prove the requested
  x264 modes, absence of `hevc_videotoolbox`, GPL runtime license, matching
  capabilities, system-only dynamic linkage, and reproducible checksums.
- Capability preflight and command/output validation must require the recipe's
  exact libx264 pixel format rather than only the encoder name. Re-probed output
  must also report the exact limited `color_range=tv`; missing or full-range
  metadata fails closed before publication. The command must force the matching
  x264 VUI signal with `fullrange=off:videoformat=component`, including when the
  input has unspecified color metadata.
- Policy and command tests must cover Quick CRF 22/medium, the unchanged
  Flexible curve, <=8-bit `yuv420p`, and 10-bit 4:2:0/4:2:2/4:4:4 mappings,
  including unsupported-chroma rejection. When the separately planned
  `compactRetry` action is implemented, its tests must enforce CRF 31 and the
  same pixel-format policy.
- Deterministic bundled integration tests must encode and re-probe synthetic
  fixtures for every supported pixel-format class. Tests must not depend on a
  personal media file, Homebrew, `PATH`, or network access.
- Complete `./Scripts/build-ffmpeg.sh`, `./Scripts/build.sh`, and
  `./Scripts/test.sh` before release.
