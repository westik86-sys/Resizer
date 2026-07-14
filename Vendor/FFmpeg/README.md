# Bundled FFmpeg toolchain

Resizer builds `ffmpeg` and `ffprobe` from the official FFmpeg 8.1.2 source.
The release tag is `n8.1.2` at commit
`38b88335f99e76ed89ff3c93f877fdefce736c13`.

The binaries are a deliberately small LGPL 2.1-or-later profile for the
toolchain spike:

- H.264 and AAC in MOV/MP4 input;
- H.264 VideoToolbox and native AAC encoders;
- MP4 output;
- local files, inherited file descriptors, and pipes only;
- no network, external libraries, GPL, nonfree, libx264, or libx265 code.

Run `./Scripts/build-ffmpeg.sh` from any directory to verify the source archive,
verify and apply the pinned patch under `patches/`, build independent `arm64`
and `x86_64` slices with the macOS SDK, merge them with `lipo`, and refresh the
capability and linkage reports under `build-config/`. The build uses a stable,
non-user-specific work root, a virtual install prefix, and compiler prefix maps
so the binaries and reports do not disclose a developer home or checkout path.
Every invocation verifies the fixed work path and its ownership, takes an
exclusive private lock, removes the previous work tree, and extracts,
configures, and compiles from scratch; source trees, configure results, and
object files are never reused. Binaries, reports, signatures, and their
checksums are first produced and verified under that fresh work root. The
checked-in `bin/`, `build-config/`, and build checksum manifest are replaced
only after the staged LGPL profile, linkage, path privacy, code signatures, and
checksums have all passed. Publication also preserves and rechecks executable
`0755` and report/manifest `0644` modes despite the private build umask. A
failed pre-publication check therefore leaves the checked-in artifacts
untouched.
Generated binary/report hashes are recorded separately in
`checksums/BUILD_SHA256SUMS`; immutable source and patch pins remain in
`checksums/SHA256SUMS`.

The archive and detached signature are retained under `sources/` as the exact
corresponding source for the distributed binaries. License texts are under
`licenses/`. The LGPL-compatible local patch extends the seekable `fd` protocol
with strict `fd:<number>` URLs and descriptor-local positional I/O on Darwin. A
MOV `faststart` reopen therefore keeps using the same inherited descriptor
without sharing its mutable offset with the writer. The descriptor must be
read-write and should reference an empty regular file; streamed descriptors
retain FFmpeg's sequential I/O behavior. See `build-config/profile.txt` for the
fixed component profile and the generated reports for the exact configure
commands and compiled features.
