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

Implementation is currently at stage 7. The production headless workflow now
retains security-scoped input and output access while it probes the source,
performs capability-aware preflight, encodes into a unique job-owned
`.partial.mp4`, parses bounded machine-readable progress, probes and validates
the result, and atomically publishes it without replacing an existing file.
Before launch, the workflow atomically reserves the temporary with `O_EXCL`
and records its device/inode seal. FFmpeg writes MP4 through an inherited,
seekable descriptor instead of reopening the pathname. Validation, cleanup,
and commit all require that identity, so every collision or replacement inode
is preserved and unsealed cleanup always fails closed.
Graceful cancellation sends `q` before the process runner escalates through
signals, and a recorded cancellation takes precedence over a later nonzero
exit. The bundled FFmpeg capabilities are queried in parallel with a bounded
15-second discovery deadline, cached only after complete success, and checked
against the selected input and recipe before launch.

The stage also includes a real bundled-tool integration test and deterministic
tests for progress parsing, capability discovery, process failures,
cancellation races, output validation, security-scoped lifetimes, symlink and
hard-link guards, exact cleanup, and no-replace commit. See
[`docs/architecture.md`](docs/architecture.md) and
[`docs/adr/0007-headless-transcoding-core.md`](docs/adr/0007-headless-transcoding-core.md)
for the complete contracts.

The temporary stage-2 diagnostic UI remains available and still uses its narrow
spike runner to prove the bundled toolchain. It is not the final product UI.
The product UI and queue remain later PLAN stages. The production headless
workflow is intentionally not wired into the temporary diagnostic UI; stage 8
will replace that spike UI with the single-file product experience.

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
ResizerUITests/     Xcode-generated UI-test target (not part of bootstrap verification)
Tests/ProcessHarness/ Deterministic native process fixture used only by unit tests
Scripts/            Shell-first build and test entry points
Vendor/FFmpeg/      Binaries, exact source, checksums, licenses, and build reports
Configuration/      Nested helper entitlements
docs/               Current architecture guide and decision records
```
