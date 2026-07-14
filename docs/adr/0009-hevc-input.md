# ADR 0009: Native HEVC input decoding

- Status: Accepted
- Date: 2026-07-14
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

The public MVP imports MOV and MP4, but the profile-6 bundled toolchain could
decode only H.264 video. Common camera and iPhone files using HEVC therefore
passed FFprobe and then failed capability preflight before encoding. The
product still needs a narrow compatibility workflow, an LGPL-only bundled
toolchain, deterministic validation, and H.264/AAC MP4 output.

## Decision

Profile 7 adds only FFmpeg's native `hevc` decoder and `hevc` parser. Both are
part of the pinned FFmpeg 8.1.2 LGPL 2.1-or-later source and select only
internal FFmpeg components. The build remains free of external libraries,
`libx265`, GPL, version3, and nonfree modes.

Supported video input is now H.264 or HEVC in MOV/MP4 under the existing SDR
policy. The preflight remains capability-driven and fails closed if the actual
bundled binary does not advertise the selected decoder. The command and output
contract do not change: Resizer still creates an H.264 VideoToolbox `yuv420p`
video with optional native AAC audio in MP4, validates it, and publishes it only
through the descriptor-owned no-replace transaction.

The scale filter converts full-range 8-bit SDR input samples to limited (`tv`)
range, and the encoder receives matching explicit range metadata. This covers
common HEVC Main camera files reported as `yuvj420p` while preserving the
existing deterministic `yuv420p` output contract.

This decision does not add HEVC output, `hevc_videotoolbox`, `libx265`, arbitrary
codec selection, HDR/Dolby Vision tone mapping, new containers, network access,
or a system/Homebrew fallback. Explicit HDR and uncertain high-bit-depth input
continue to fail under the existing conservative SDR guard.

## Consequences

- Existing HEVC Main SDR camera files can enter the normal queue and produce
  the same compatible H.264/AAC result as H.264 sources.
- Software HEVC decoding increases the bundled binary size and may use more CPU
  than a hardware-decoding path; hardware decode is a separate performance
  decision.
- Reproducible build reports and checksum evidence must record the HEVC decoder
  and parser for both Universal 2 slices while continuing to reject forbidden
  license modes and encoders.
- HEVC input receives a deterministic signed integration test; tests continue
  to run without network access, `PATH`, Homebrew, or personal media.

## Verification

- `./Scripts/build-ffmpeg.sh`
- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Infrastructure/FFmpegCapabilitiesTests.swift`
- `ResizerTests/Infrastructure/FFmpegCommandBuilderTests.swift`
- `ResizerTests/Integration/HeadlessTranscodingIntegrationTests.swift`
- `Vendor/FFmpeg/build-config/configure-arm64.mak`
- `Vendor/FFmpeg/build-config/configure-x86_64.mak`
- `Vendor/FFmpeg/build-config/decoders.txt`
- `Vendor/FFmpeg/checksums/BUILD_SHA256SUMS`
