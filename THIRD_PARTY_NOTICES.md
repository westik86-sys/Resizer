# Third-party notices

## FFmpeg

Resizer bundles FFmpeg 8.1.2 "Hoare" (tag `n8.1.2`) and builds it under
GNU GPL version 2 or later because the profile links libx264.

- Project: <https://ffmpeg.org/>
- Corresponding source: `Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz`
- Local patch: `Vendor/FFmpeg/patches/`
- Build instructions: `Scripts/build-ffmpeg.sh`
- License texts: `Vendor/FFmpeg/licenses/`
- Exact configuration and capability reports: `Vendor/FFmpeg/build-config/`

FFmpeg is not owned by the Resizer project. Individual FFmpeg components retain
their upstream LGPL/GPL terms. The resulting bundled executables report
GPL version 2 or later. The profile excludes nonfree code and libx265.

## x264

The bundled FFmpeg tools statically link x264 commit
`0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee` (core 165, r3223).

- Project: <https://code.videolan.org/videolan/x264>
- Corresponding source: `Vendor/x264/sources/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz`
- Reproducible version-metadata patch: `Vendor/x264/patches/`
- Checksum and provenance: `Vendor/x264/README.md`
- License: GNU GPL version 2 or later
- License text: `Vendor/x264/licenses/COPYING`

The project source and all retained build materials are available at
<https://github.com/westik86-sys/Resizer>. Direct-distribution releases also
include a version-matched corresponding-source archive under `Open Source`.
