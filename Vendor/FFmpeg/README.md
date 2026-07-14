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
capability and linkage reports under `build-config/`.

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
