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
- Bundled toolchain: FFmpeg 8.1.2, minimal LGPL 2.1-or-later profile

Implementation is at stage 10. The native product UI supports multi-file MOV
and MP4 import, one sequential FIFO queue, three typed presets, bounded custom
settings, safe output naming, progress and ETA, cancellation, retry, reordering,
results, and Finder reveal. English and Russian localizations, keyboard access,
VoiceOver-focused state changes, actionable typed errors, and redacted bounded
diagnostics are included.

Supported video inputs are H.264 and HEVC in MOV/MP4 under the existing SDR
policy. The compatibility output remains H.264 VideoToolbox with optional AAC
in MP4; HEVC output, HDR tone mapping, libx265, GPL, and nonfree components are
not included.

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
pinned official source with an LGPL-only profile. The app includes the exact
third-party notice and LGPL texts and exposes them in Settings. Deterministic
tests cover the state machine, queue races, process teardown, validation,
filesystem publication paths, localization, accessibility-facing copy, and a
real bundled `probe → transcode → probe` flow. See
[`docs/architecture.md`](docs/architecture.md),
[`docs/adr/0007-headless-transcoding-core.md`](docs/adr/0007-headless-transcoding-core.md),
[`docs/adr/0008-stage-10-hardening.md`](docs/adr/0008-stage-10-hardening.md),
and [`docs/adr/0009-hevc-input.md`](docs/adr/0009-hevc-input.md).

Sandbox checkpoint A passed locally on 2026-07-13: an ad hoc-signed Universal 2
Release app used PowerBox-selected input and output locations to run bundled
`ffprobe`, encode three seconds with bundled `ffmpeg`, and validate and commit
the resulting MP4. The command and evidence are recorded in
[`docs/adr/0002-bundled-ffmpeg-toolchain.md`](docs/adr/0002-bundled-ffmpeg-toolchain.md).
Developer ID signing, notarization, and Gatekeeper validation remain release-stage
work.

## Requirements

- A macOS host with Xcode capable of building Swift 6 projects for macOS 14+
- No Homebrew packages or globally installed FFmpeg are required
- Building the bundled toolchain requires the official source archive retained
  under `Vendor/FFmpeg/sources/`

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
Configuration/      Nested helper entitlements
docs/               Current architecture guide and decision records
```
