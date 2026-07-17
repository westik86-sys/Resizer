# ADR 0014: Software H.264 with libx264 and GPL distribution

- Status: Accepted
- Date: 2026-07-17
- Supersedes: the ordinary H.264 encoder, H.264 rate-control, LGPL-only toolchain,
  and corresponding-source portions of ADRs 0001, 0002, 0006, 0007, 0008,
  0009, 0010, 0011, 0012, and 0013

## Context

Comparative tests showed a better quality/size result from CompressO with the
thunderbolt preset, 100% quality, and H.264. At CompressO commit
41ee3f8e27bf407019ed300ea8e5208319073d5c, its video command chooses
libx264 by default. thunderbolt adds no explicit x264 preset, so libx264 uses
its default medium. Its integer quality mapping is:

    CRF = 36 - floor(12 × qualityPercent / 100)

At 100% this is CRF 24. The previous Resizer H.264 path used
h264_videotoolbox and VideoToolbox global_quality; that is a different encoder
and rate-control model, so matching the numeric quality label could not
reproduce CompressO's trade-off.

libx264 is GPL version 2 or later. Enabling it in FFmpeg requires
--enable-gpl, changes the distributed FFmpeg tool license profile, and requires
reproducible corresponding-source delivery. The project owner chose a fully
open-source application and accepted GPL-2.0-or-later distribution.

## Decision

- Ordinary supported SDR sources encode as 8-bit limited-range H.264 with
  libx264, yuv420p, CRF 24, and preset medium in Quick mode.
- Flexible retains its product quality bound of 30...90% and maps it through the
  CompressO formula above, yielding integer CRF 33...26.
- Confirmed >8-bit SDR retains the existing HEVC Main10 VideoToolbox path and
  its normalized global_quality model.
- CRF and VideoToolbox quality are distinct validated domain types. The command
  builder rejects mismatched codec/rate-control pairs.
- The bundled FFmpeg 8.1.2 profile enables GPL and statically links x264 core
  165/r3223 at commit 0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.
- The profile continues to exclude --enable-version3, --enable-nonfree,
  libx265, network support, and package-manager libraries.
- The arm64 x264 slice uses assembly. The x86_64 slice uses x264's C path until
  a separately sourced and licensed NASM build dependency is explicitly
  approved; this affects Intel speed, not CRF semantics or output format.
- Resizer is licensed GPL-2.0-or-later. The app bundles GPLv2, relevant LGPL
  texts, and exact third-party notices.
- Every direct binary release includes a version-matched full source archive:
  Resizer source/tests/project/scripts plus the pinned FFmpeg and x264 sources,
  patch, licenses, checksums, and build evidence.

## Build and verification contract

Scripts/build-ffmpeg.sh builds x264 per architecture before FFmpeg. A
fail-closed pkg-config shim exposes only that staged static library. The build
checks source hashes, x264 ABI/symbols, architecture, PIC/deployment settings,
FFmpeg GPL configuration, capabilities, runtime license output, system-only
dynamic linkage, path privacy, signatures, and generated checksums before
atomically publishing the tools.

The command and policy tests must assert libx264, CRF, medium, the bounded
quality mapping, mismatched rate-control rejection, and libx264 capability
preflight. Integration tests must complete the real bundled
probe → transcode → probe path.

## Consequences

H.264 encoding is CPU-bound and is expected to be slower and more
energy-intensive than VideoToolbox, especially on Intel while assembly is
disabled. In return, the chosen Quick result matches the tested CompressO
encoder/rate-control pair and is deterministic across compatible machines.

GPL obligations apply to distribution even though FFmpeg runs as a child
process. The version-matched source bundle and notices are release gates.
Open-source/noncommercial distribution does not by itself remove possible H.264
patent obligations; distribution-channel changes require separate review.
