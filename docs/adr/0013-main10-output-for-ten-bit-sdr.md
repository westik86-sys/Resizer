# ADR 0013: Preserve ten-bit SDR with HEVC Main10

- Status: Implemented
- Date: 2026-07-16
- Source of truth: [`PLAN.md`](../../PLAN.md)
- Amends: [`ADR 0009`](0009-hevc-input.md),
  [`ADR 0012`](0012-quick-flexible-compression.md)

## Context

The compatibility-only H.264 path converts every input to 8-bit `yuv420p`.
A real 10-bit 4:4:4 SDR input with smooth dark gradients fell from about
49 Mbit/s to about 2 Mbit/s and developed visible banding and block artifacts.
Increasing H.264 quality alone cannot restore tonal precision lost during the
10-to-8-bit conversion.

## Decision

Codec choice remains a closed deterministic product policy derived from the
selected source stream:

- confirmed SDR sources above eight bits use `hevc_videotoolbox`, Main10,
  `p010le`, MP4 tag `hvc1`, and software VideoToolbox fallback when hardware
  Main10 is unavailable;
- ordinary supported sources use `h264_videotoolbox` and `yuv420p`;
- reduction to a lower output depth uses error-diffusion dithering;
- HDR and unknown-range inputs whose bit depth is not proven safe remain
  rejected; this decision does not add tone mapping.

Quick uses normalized VideoToolbox quality `0.70` for Main10 and `0.75` for
H.264. Flexible retains its bounded user quality and the same source-derived
codec policy. Compact retry uses `0.60` for Main10 and `0.45` for H.264.

The UI reports the resulting codec but does not expose codec, pixel format,
profile, bitrate, or raw FFmpeg flags as editable controls. A captured recipe
therefore remains immutable and fully validates against the actual bundled
encoder set and the probed output.

## Consequences

- Dark gradients retain ten-bit precision instead of being quantized to eight
  bits before encoding.
- HEVC normally improves size at equivalent subjective quality, while
  VideoToolbox keeps processing local and hardware-accelerated when available.
- HEVC compatibility is narrower than H.264; the `hvc1` tag and MP4 container
  cover Apple playback, but external service smoke tests remain a release gate.
- The bundled profile adds only the native `hevc_videotoolbox` encoder. It does
  not add `libx265`, GPL, nonfree code, network support, or a new dependency.
- Reproducible build reports, capability preflight, output validation, golden
  command tests, and signed integration tests cover both output paths.

## Alternatives considered

### Raise H.264 quality globally

Rejected as the primary fix. It increases every output and reduces block
artifacts but still discards two bits of gradient precision for 10-bit input.

### Apply a debanding filter to every input

Rejected. Global debanding can soften intentional detail and add noise that
costs bitrate. Dithering is limited to actual bit-depth reduction instead.

### Bundle libx265

Rejected. It changes the license profile and is unnecessary while the native
VideoToolbox Main10 path meets the product requirement.
