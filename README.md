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

Implementation is currently at stage 4. In addition to the architecture
scaffold, the project now contains a generic actor-owned `ProcessRunner` with
direct executable launch, simultaneous pipe draining, finite async event
buffering, bounded stderr diagnostics, and awaited cancellation escalation. A
test-only native `ProcessHarness` covers large simultaneous output, literal
arguments, graceful and forced cancellation, races, and delayed pipe EOF. See
[`docs/architecture.md`](docs/architecture.md) for the dependency, process, and
state-transition contracts.

The temporary stage-2 diagnostic UI remains available and still uses its narrow
spike runner to prove the bundled toolchain. It is not the final product UI. A
FFprobe mapping, preset-to-argument behavior, the headless compression workflow,
and the queue remain later PLAN stages. The stage-4 runner is not yet wired into
the temporary diagnostic UI.

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
Resizer/            SwiftUI app plus Domain/Application/Infrastructure/UI layers
ResizerTests/       Swift Testing domain, application, and boundary tests
ResizerUITests/     Xcode-generated UI-test target (not part of bootstrap verification)
Tests/ProcessHarness/ Deterministic native process fixture used only by unit tests
Scripts/            Shell-first build and test entry points
Vendor/FFmpeg/      Binaries, exact source, checksums, licenses, and build reports
Configuration/      Nested helper entitlements
docs/               Current architecture guide and decision records
```
