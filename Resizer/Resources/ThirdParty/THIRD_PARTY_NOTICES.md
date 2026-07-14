# Third-party notices

## FFmpeg

This software uses code from the FFmpeg project under the GNU Lesser General
Public License, version 2.1 or later.

- Project: <https://ffmpeg.org/>
- Bundled version: FFmpeg 8.1.2 "Hoare", tag `n8.1.2`
- Corresponding source: included in the direct-distribution DMG under
  `Open Source` as a versioned `ffmpeg-source.tar.xz` bundle, and retained in
  the project at `Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz`
- Build instructions: `Scripts/build-ffmpeg.sh`
- License texts: `Vendor/FFmpeg/licenses/`
- Exact configuration and capability reports: `Vendor/FFmpeg/build-config/`

The bundled profile does not enable GPL or nonfree FFmpeg components and does
not include libx264 or libx265. FFmpeg is not owned by the Resizer project.

The project repository and build materials are available at
<https://github.com/westik86-sys/Resizer>.
