# Bundled FFmpeg toolchain

Resizer builds `ffmpeg` and `ffprobe` from the official FFmpeg 8.1.2
"Hoare" source. The release tag is `n8.1.2` at commit
`38b88335f99e76ed89ff3c93f877fdefce736c13`.

The binaries use a deliberately small GPL 2.0-or-later profile:

- H.264 or HEVC video and AAC audio in MOV/MP4 input;
- software H.264 through statically linked libx264, HEVC Main10 through
  VideoToolbox, and the native AAC encoder;
- MP4 output;
- local files, inherited file descriptors, and pipes only;
- no network, nonfree components, libx265, or package-manager libraries.

x264 is built first from the pinned source under `Vendor/x264/`. A fail-closed
pkg-config shim exposes only that staged static library to FFmpeg. No installed
FFmpeg or x264 is used. The arm64 x264 slice uses assembly; x86_64 currently
uses the dependency-free C implementation because Xcode does not include NASM.
That affects Intel encoding speed, not CRF behavior or output compatibility.

Run `./Scripts/build-ffmpeg.sh` from any directory to verify both source
archives, verify and apply the pinned FFmpeg patch, build independent `arm64`
and `x86_64` slices with the macOS SDK, merge them with `lipo`, and refresh the
reports under `build-config/`. The build uses a stable, non-user-specific work
root, a virtual FFmpeg prefix, and compiler prefix maps so artifacts do not
disclose a developer home or checkout path.

Every invocation validates ownership and fixed paths, takes an exclusive lock,
removes only its known work tree, and builds from fresh sources. It checks the
x264 ABI and architecture, the macOS 14 deployment target, the required GPL
and codec capabilities, system-only dynamic linkage, path privacy, signatures,
and checksums before publishing. The checked-in `bin/`, `build-config/`, and
`checksums/BUILD_SHA256SUMS` are replaced only after all staged checks pass.

The unmodified FFmpeg archive and detached signature are retained under
`sources/`. FFmpeg license texts are under `licenses/`; the x264 source,
license, and checksum are retained under `Vendor/x264/`. The local FFmpeg patch
extends the seekable `fd` protocol with strict `fd:<number>` URLs and
Darwin descriptor-local positional I/O, allowing MOV `+faststart` to keep using
the reserved inherited descriptor safely. See `build-config/profile.txt` for
the fixed profile and the generated reports for exact configuration evidence.
