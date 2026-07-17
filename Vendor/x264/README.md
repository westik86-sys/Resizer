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

`Scripts/build-ffmpeg.sh` builds a static 8-bit 4:2:0 library for each target
architecture before configuring FFmpeg. The arm64 slice uses x264 assembly;
the x86_64 slice disables assembly because the pinned Xcode toolchain does not
provide NASM. This changes encoding speed, not the encoded format or CRF
quality contract. No installed x264 library or package manager is used.

x264 is licensed under GNU GPL version 2 or later. The unmodified upstream
license is retained in `licenses/COPYING`.
