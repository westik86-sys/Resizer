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

Implementation is currently at the stage-2 toolchain spike. The app embeds
Universal 2 `ffmpeg` and `ffprobe` executables and exposes a temporary diagnostic
flow for a short H.264/AAC MOV or MP4 encode. It is not the final product UI and
does not include the architecture layer, general process runner, presets, or a
queue.

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

Developer ID identities and credentials are intentionally not stored in the repository. Shell verification disables code signing; signing and notarization belong to the release stage.

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
Resizer/            Minimal SwiftUI application
ResizerTests/       Swift Testing unit-test target
ResizerUITests/     Xcode-generated UI-test target (not part of bootstrap verification)
Scripts/            Shell-first build and test entry points
Vendor/FFmpeg/      Binaries, exact source, checksums, licenses, and build reports
Configuration/      Nested helper entitlements
docs/adr/           Architecture decision records
```
