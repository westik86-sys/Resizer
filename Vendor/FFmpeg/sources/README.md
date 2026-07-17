# Corresponding FFmpeg source

`ffmpeg-8.1.2.tar.xz` is the unmodified source archive downloaded from:

<https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz>

`ffmpeg-8.1.2.tar.xz.asc` is its detached signature downloaded from:

<https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz.asc>

The release signing key is published at <https://ffmpeg.org/ffmpeg-devel.asc>.
Its documented fingerprint is:

```text
FCF986EA15E6E293A5644F10B4322F04D67658D8
```

The local SHA-256 values are pinned in `../checksums/SHA256SUMS`. FFmpeg does
not publish a SHA-256 sidecar for this archive. The detached signature should
also be verified with the official key on a host with GnuPG before release.

The archive remains unmodified. `../patches/0001-avformat-fd-accept-descriptor-in-url.patch`
is verified separately and applied to the extracted tree by
`Scripts/build-ffmpeg.sh`. Its checksum is pinned in the same manifest.

The GPL profile also links the separately pinned x264 source retained under
`Vendor/x264/`; see `Vendor/x264/README.md` for its commit, archive checksum,
license, and build details.
