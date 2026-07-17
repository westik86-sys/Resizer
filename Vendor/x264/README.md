# Bundled x264 source

Resizer builds x264 statically into its bundled FFmpeg tools. The source is
pinned to official VideoLAN commit
`0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee` (2025-09-10) and retained as
`sources/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz`.

Upstream: <https://code.videolan.org/videolan/x264.git>

The archive is a deterministic `git archive` of that commit, compressed with
`gzip -n`. Verify it with:

```sh
(cd Vendor/x264 && shasum -a 256 -c checksums/SHA256SUMS)
```

The retained patch under `patches/` injects the pinned r3223/short-commit
metadata when building from the archive, which intentionally contains no
`.git` directory. Its checksum is covered by the same manifest.

`Scripts/build-ffmpeg.sh` builds one static library for each target architecture
with `--bit-depth=all` and `--chroma-format=all`. Each library therefore
contains the 8- and 10-bit encoder implementations and supports planar 4:0:0,
4:2:0, 4:2:2, and 4:4:4 input, including `yuv444p10le` through FFmpeg. The
arm64 slice uses x264 assembly; the x86_64 slice disables assembly because the
pinned Xcode toolchain does not provide NASM. This changes encoding speed, not
the encoded format or CRF quality contract. No installed x264 library or
package manager is used.

The build compiles and runs `tests/encode-smoke.c` against each architecture's
static library. The smoke must produce a non-empty H.264 bitstream for every
8/10-bit planar chroma combination before FFmpeg can be built. A second smoke
then invokes each architecture's final FFmpeg and FFprobe command-line wrappers
against the checksum-pinned synthetic fixture under
`ResizerTests/Fixtures/Media/`, and verifies the four product pixel formats
before either helper can be published.

x264 is licensed under GNU GPL version 2 or later. The unmodified upstream
license is retained in `licenses/COPYING`.
