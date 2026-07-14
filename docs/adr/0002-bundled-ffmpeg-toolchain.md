# ADR 0002: Bundled FFmpeg toolchain spike

- Status: Accepted for implementation stage 2; component profile amended by
  [`ADR 0009`](0009-hevc-input.md)
- Date: 2026-07-13

## Context

Resizer must probe and compress local video without relying on Homebrew, the
user's `PATH`, or network access. The closed-source application needs a
redistributable, auditable FFmpeg profile for both Apple Silicon and Intel. The
first checkpoint must also prove that externally built tools launch as nested
executables of a signed sandboxed app.

## Decision

Bundle the `ffmpeg` and `ffprobe` CLI executables built from the unmodified
official FFmpeg 8.1.2 source archive. Pin release tag `n8.1.2`, commit
`38b88335f99e76ed89ff3c93f877fdefce736c13`, the detached release signature,
and locally calculated SHA-256 checksum.

Use the minimal component profile recorded in
`Vendor/FFmpeg/build-config/profile.txt`. The current profile accepts H.264 or
HEVC video and AAC audio in MOV or MP4, encodes H.264 through VideoToolbox and
audio through FFmpeg's native AAC encoder, writes MP4, and enables only
local-file, descriptor, and pipe protocols. Network, external libraries, GPL,
nonfree, libx264, and libx265 are excluded.

Build independent `arm64` and `x86_64` slices with the same macOS 14 component
profile. Disable standalone x86 assembly to avoid a NASM dependency, retain
compiler inline assembly, compare both slices' capability lists, and merge the
executables with `lipo`.

Pre-sign each tool ad hoc with Hardened Runtime, a unique identifier, and only
these helper entitlements:

```text
com.apple.security.app-sandbox = true
com.apple.security.inherit = true
```

Embed them with an Xcode Copy Files phase targeting Executables and enable Code
Sign On Copy. Production Swift code resolves them only with
`Bundle.main.url(forAuxiliaryExecutable:)` and launches them directly through
`Process`, never through a shell.

## Sandbox checkpoint

The temporary stage-2 UI keeps security-scoped input and output URLs active for
the entire probe, encode, validation, and rename operation. A real signed-app
test is mandatory because inherited static sandbox rights do not by themselves
prove that PowerBox access selected after launch reaches an external CLI tool.
If direct access is rejected, the resolution must not be broader helper
entitlements; it requires a documented data-transfer or helper architecture.

That rename records the historical stage-2 spike, not the production stage-7
publication contract. The headless core now creates and immediately unlinks an
`O_RDWR` temporary, passes that exact file as child fd 3, validates the same fd
with FFprobe, and publishes it with no-replace `fclonefileat`. It does not
rename a temporary pathname.

### Verification record

Checkpoint A passed on 2026-07-13 with a local ad hoc signature. The sandboxed
Release app was built as Universal 2 with:

```sh
xcodebuild \
  -project Resizer.xcodeproj \
  -scheme Resizer \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/SignedDerivedData \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  'ARCHS=arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  build
```

The test selected a generated H.264 MP4 and a separate output directory through
the two system PowerBox dialogs. Inside App Sandbox, bundled `ffprobe` detected
the input video and bundled `ffmpeg` produced a non-empty temporary file. A
second bundled probe validated H.264 in MP4 before the app renamed the temporary
file to a unique final name.

Observed output:

- duration: `3.000000` seconds;
- video: H.264, 640x360, `yuv420p`;
- size: 618,123 bytes;
- no `.partial.mp4` remained;
- selected input SHA-256 after the run:
  `2b583df8793d843106cf1ce1dc09104f3bb36e0bb7698d8cc09fae2a0b37f7a3`.

`Resizer`, `ffmpeg`, and `ffprobe` each contain `arm64` and `x86_64`, target
macOS 14.0, have executable mode 755, and pass strict all-architecture code-sign
verification. The app has only App Sandbox plus user-selected read/write access;
each helper has only App Sandbox plus inherit. All three binaries use Hardened
Runtime and link only system libraries.

This proves local sandbox inheritance and PowerBox access. It does not prove the
Developer ID, notarization, or Gatekeeper release path: the checkpoint artifact
has an ad hoc signature and no Team ID. Those checks remain stage 11 work.

## Consequences

- The spike intentionally supports a smaller input matrix than the eventual
  product. New demuxers and decoders require an explicit profile and license
  review.
- The exact corresponding source and LGPL notices are distributed with the
  repository and can accompany release artifacts.
- The two roughly 10 MB Universal 2 executables increase the app size but avoid
  dynamic-framework signing and ABI complexity.
- A tool signed with `com.apple.security.inherit` is expected to run as a child
  of the sandboxed app, not as a standalone Terminal command. Unsigned thin
  build outputs are used for build-time capability reports.

## References

- <https://ffmpeg.org/download.html>
- <https://ffmpeg.org/legal.html>
- <https://ffmpeg.org/ffprobe.html>
- <https://developer.apple.com/documentation/Xcode/embedding-a-helper-tool-in-a-sandboxed-app>
- <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>
