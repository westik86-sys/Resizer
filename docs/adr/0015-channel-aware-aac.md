# ADR 0015: Channel-aware AAC bitrate

- Status: Implemented
- Date: 2026-07-17
- Source of truth: [`PLAN.md`](../../PLAN.md)
- Supersedes: the fixed first-attempt AAC bitrate portions of
  [`ADR 0011`](0011-automatic-compression.md) and
  [`ADR 0012`](0012-quick-flexible-compression.md)
- Does not change: the separate `compactRetry` AAC policy

## Context

After the H.264 path moved to libx264 CRF 24 with preset `medium`, comparative
encodes still showed that CompressO produced a smaller mono file with the same
visual video result. The video settings were already equivalent. Resizer
explicitly requested AAC at 128,000 bit/s for every selected audio stream,
while CompressO omitted `-b:a` and received the native FFmpeg AAC encoder's
channel-dependent default.

In the pinned FFmpeg 8.1.2 source, that default is 69,000 bit/s for a mono SCE
and 128,000 bit/s for a stereo pair. A controlled five-second mono encode using
the complete Quick video recipe measured 496,360 bytes for CompressO's default
and 496,371 bytes for explicit 69,000 bit/s: a difference of 11 bytes, or
0.0022%. Explicit 128,000 bit/s produced 532,411 bytes. Stereo remained closest
at explicit 128,000 bit/s, differing from CompressO by 26 bytes, or 0.0049%.
The encoded video packet SHA-256 was identical across all tested AAC rates.

## Decision

- The selected audio stream is the lowest-index default stream, or the lowest
  absolute audio-stream index when no default exists.
- Recipe derivation, capability preflight, and FFmpeg command mapping use one
  shared `preferredAudioStream` selection so bitrate cannot be calculated from
  a different stream than the one encoded.
- When `Keep Audio` is enabled and the selected stream reports exactly one
  channel, Quick and Flexible use AAC at 69,000 bit/s.
- Stereo, multichannel, and unknown channel counts retain AAC at 128,000 bit/s.
  A layout string alone is not used to infer mono when channel count is absent.
- Missing source audio or `Keep Audio` disabled produces no output audio
  stream.
- FFmpeg receives the captured typed bitrate explicitly. Resizer does not rely
  on an encoder default that could change between toolchain revisions.
- Video codec, CRF/quality, preset, scaling, frame-rate, pixel-format, and
  metadata policies are unchanged.

## Consequences

- Mono outputs closely match CompressO's overall size without changing the
  encoded video payload.
- Stereo behavior is unchanged. Unknown channel counts keep the prior
  128 kbit/s rate rather than risking an accidental quality regression.
- Surround input keeps the existing single-stream mapping and 128 kbit/s
  fallback. This decision does not claim complete multichannel-layout support;
  such support requires separate preflight, output validation, and integration
  coverage.
- Audio bitrate remains an internal closed product policy and is not exposed as
  a user-editable FFmpeg setting.

## Verification

- policy tests cover Quick and Flexible mono AAC at 69 kbit/s;
- policy tests keep stereo, multichannel, and unknown channel counts at
  128 kbit/s;
- stream-selection tests prove that bitrate and command mapping use the same
  preferred source stream;
- the existing stereo golden command remains unchanged;
- comparative mono/stereo encodes verify size parity with CompressO and an
  unchanged video packet hash;
- `./Scripts/build.sh`;
- `./Scripts/test.sh`.
