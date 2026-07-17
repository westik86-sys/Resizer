# Resizer

Resizer is a native macOS utility for creating smaller, compatible video copies locally. The original media is always treated as immutable. See [`PLAN.md`](PLAN.md) for complete product and technical requirements and [`AGENTS.md`](AGENTS.md) for repository working rules.

## Current status

- App name and scheme: `Resizer`
- Bundle identifier: `com.example.Resizer`
- Deployment target: macOS 14+
- Language and UI: Swift 6 with strict concurrency, SwiftUI
- Architectures: standard macOS architectures (`arm64` and `x86_64`) for public Release builds
- App Sandbox: enabled with user-selected read/write access; network access disabled
- Hardened Runtime: enabled for the planned Developer ID channel
- Planned first distribution channel: Developer ID with notarization
- Bundled toolchain: FFmpeg 8.1.2 with static x264, minimal GPL 2.0-or-later profile

Implementation has completed stage 10 and is preparing the direct-DMG portion
of stage 11. The native product UI supports multi-file MOV and MP4 import, one
sequential FIFO queue, bounded Quick/Flexible compression controls, safe output
naming, progress and ETA, cancellation, retry, reordering, neutral no-benefit
results, and Finder reveal.
English and Russian localizations, keyboard access,
VoiceOver-focused state changes, actionable typed errors, and redacted bounded
diagnostics are included.

Supported video inputs are H.264 and HEVC in MOV/MP4 under the existing SDR
policy. Every supported SDR source is encoded to H.264 through software
libx264. Sources at or below 8-bit produce compatible `yuv420p`; confirmed
sources above 8-bit retain ten-bit precision and supported source chroma as
`yuv420p10le`, `yuv422p10le`, or `yuv444p10le`. All paths produce MP4 with
optional AAC. HDR tone mapping, libx265, and nonfree components are not
included.

Kept audio follows the same deterministic default that CompressO receives from
FFmpeg: the selected mono stream is encoded as AAC at 69 kbit/s, while stereo,
multichannel, and unknown channel counts retain AAC at 128 kbit/s. Resizer
emits both values explicitly so equal probed inputs always capture equal
recipes; removing audio or an input without audio still produces no audio
stream.

Quick uses `libx264`, CRF 22, and preset `medium`. It deliberately spends more
bits than CompressO's `thunderbolt` preset at 100% (CRF 24) to retain a larger
quality margin while preserving the same software encoder and preset.
Flexible keeps the product's 30...90% quality bound and applies the integer
curve
`CRF = 36 - floor(12 × qualityPercent / 100)`, producing CRF 33...26. CRF is
kept as a typed internal policy and is not exposed as an arbitrary FFmpeg flag.
The planned `compactRetry` action remains specified as libx264 CRF 31; its
separate secondary-action implementation is outside this encoder-policy stage.

Ten-bit 4:2:0, 4:2:2, and 4:4:4 H.264 outputs use High 10, High 4:2:2, or High
4:4:4 Predictive profiles and are less widely hardware-decoded than ordinary
8-bit 4:2:0 H.264.
Preserving the source precision and chroma avoids the visible loss caused by
converting such material to 8-bit 4:2:0. Any compatibility claim for a named
external player or upload service requires a recorded release smoke test for
that exact target.

The application coordinator remains the sole workflow owner. It retains
security-scoped input and output access through probe, capability preflight,
encode, validation, and publication. FFmpeg writes to the exact per-job staging
descriptor as `fd:3`; stdout is reserved for `-progress pipe:1`, and stderr is
kept only as a bounded diagnostic tail. Normal application termination first
cancels the queue and waits for every child process and pipe to finish, so a
normal quit cannot leave an FFmpeg process behind.

Publication never replaces the original or an existing final file and requires
a clone-capable output filesystem. Resizer writes through an anonymous staging
descriptor and publishes it with no-replace `fclonefileat`. Unsupported volumes
fail before encode; there is no named, path-based rename or copy fallback.
Failure and cancellation close only the job's anonymous lease, never a glob or
a later pathname replacement.

The bundled FFmpeg 8.1.2 tools are reproducibly built as Universal 2 from the
pinned official FFmpeg and x264 sources with a GPL 2.0-or-later profile. x264
is configured for all supported bit depths and chroma formats; the minimal
profile retains HEVC input decoding but no HEVC output encoder. The app includes
the exact third-party notices and GPL/LGPL texts and exposes them in Settings.
Deterministic
tests cover the state machine, queue races, process teardown, validation,
filesystem publication paths, localization, accessibility-facing copy, and a
real bundled `probe → transcode → probe` flow. See
[`docs/architecture.md`](docs/architecture.md),
[`docs/adr/0016-libx264-high-bit-depth-chroma.md`](docs/adr/0016-libx264-high-bit-depth-chroma.md),
[`docs/adr/0014-libx264-gpl-toolchain.md`](docs/adr/0014-libx264-gpl-toolchain.md),
[`docs/adr/0015-channel-aware-aac.md`](docs/adr/0015-channel-aware-aac.md),
[`docs/adr/0011-automatic-compression.md`](docs/adr/0011-automatic-compression.md),
[`docs/adr/0007-headless-transcoding-core.md`](docs/adr/0007-headless-transcoding-core.md),
[`docs/adr/0008-stage-10-hardening.md`](docs/adr/0008-stage-10-hardening.md),
and [`docs/adr/0009-hevc-input.md`](docs/adr/0009-hevc-input.md).

Sandbox checkpoint A passed locally on 2026-07-13: an ad hoc-signed Universal 2
Release app used PowerBox-selected input and output locations to run bundled
`ffprobe`, encode three seconds with bundled `ffmpeg`, and validate and commit
the resulting MP4. The command and evidence are recorded in
[`docs/adr/0002-bundled-ffmpeg-toolchain.md`](docs/adr/0002-bundled-ffmpeg-toolchain.md).
Developer ID signing, notarization, and Gatekeeper validation remain blocked
until a release identity and Keychain notary profile are supplied. The
fail-closed DMG workflow is documented in
[`docs/RELEASING.md`](docs/RELEASING.md); App Store and TestFlight delivery are
not part of the first beta channel.

## Requirements

- A macOS host with Xcode capable of building Swift 6 projects for macOS 14+
- No Homebrew packages or globally installed FFmpeg are required
- Building the bundled toolchain requires the official source archive retained
  under `Vendor/FFmpeg/sources/` and the pinned x264 snapshot under
  `Vendor/x264/sources/`

Developer ID identities and credentials are intentionally not stored in the
repository. The build script disables signing. The test script uses Xcode's
ephemeral local signing so the sandboxed integration test can launch the
bundled executables; Developer ID signing and notarization belong to the
release stage.

## Build and test

From the repository root:

```sh
./Scripts/build.sh
./Scripts/test.sh
```

Rebuild and audit the bundled Universal 2 tools with:

```sh
./Scripts/build-ffmpeg.sh
```

Prepare a direct Developer ID DMG only after reading the release gates:

```sh
./Scripts/archive.sh
./Scripts/export.sh
# Explicit external operation:
DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=Resizer-notary \
  ./Scripts/notarize.sh .build/Release/Resizer-1.0-1.dmg
DEVELOPMENT_TEAM=ABCDE12345 \
  ./Scripts/verify-release.sh .build/Release/Resizer-1.0-1.dmg
```

The release scripts do not publish artifacts and never store credentials in
the repository. See
[`ADR 0010`](docs/adr/0010-direct-dmg-beta.md) for the channel decision.

Both scripts keep Derived Data under `.build/DerivedData` and can be redirected with `DERIVED_DATA_PATH`:

```sh
DERIVED_DATA_PATH=/tmp/ResizerDerivedData ./Scripts/test.sh
```

To work in Xcode, open `Resizer.xcodeproj` and use the `Resizer` scheme with the `My Mac` destination.

## Project structure

```text
Resizer.xcodeproj/  Xcode project
Resizer/            SwiftUI app plus Domain/Application/Infrastructure/UI layers
ResizerTests/       Swift Testing domain, application, and boundary tests
ResizerUITests/     Product UI, localization, and accessibility smoke tests
Tests/ProcessHarness/ Deterministic native process fixture used only by unit tests
Scripts/            Shell-first build and test entry points
Vendor/FFmpeg/      Binaries, exact source, checksums, licenses, and build reports
Vendor/x264/        Pinned x264 source, checksum, and upstream GPL license
Configuration/      Nested helper entitlements
docs/               Current architecture guide and decision records
```

## License

Resizer is free and open-source software licensed under
[`GPL-2.0-or-later`](LICENSE). The copyright and “or later” election are
recorded in [`COPYRIGHT`](COPYRIGHT). Bundled third-party components retain
their own notices and license texts; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
