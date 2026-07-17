# Direct DMG beta release

This workflow produces a Developer ID-signed, notarized DMG for direct beta
distribution. Mac App Store, TestFlight, App Store Connect metadata, store
provisioning, receipts, and installer packages are intentionally out of scope.

The release scripts fail closed. They do not read passwords or API keys from
the repository, do not accept notarization secrets as command-line arguments,
do not overwrite an existing artifact, and do not publish anything.

## Release gates

Before an external beta, explicitly confirm:

- the permanent bundle identifier (currently `com.example.Resizer`);
- marketing version and build number;
- a real application icon (the current AppIcon catalog has no PNG artwork);
- copyright text;
- Developer ID Application identity and Team ID;
- final GPL/libx264/H.264/HEVC compliance review;
- an Intel or Rosetta smoke test for the `x86_64` slice.

The Xcode project currently has no application category. That is not required
for this direct DMG beta, but it remains store metadata to resolve before any
future App Store submission.

Do not change bundle identity, entitlements, deployment target, architecture,
or the pinned GPL 2.0-or-later profile as an incidental release fix.

## Prerequisites

- A clean checkout on a supported macOS/Xcode host.
- A valid `Developer ID Application` identity in the login Keychain.
- The corresponding 10-character Apple Developer Team ID.
- A `notarytool` profile stored in Keychain.

List signing identities without exporting private keys:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials interactively so the password never enters the
repository or shell history:

```sh
xcrun notarytool store-credentials Resizer-notary
```

Only the profile name is passed to the release script.

## 1. Preflight

Run from the repository root:

```sh
git status --short
./Scripts/build.sh
./Scripts/test.sh
(
  cd "$(git rev-parse --show-toplevel)"
  shasum -a 256 -c Vendor/FFmpeg/checksums/BUILD_SHA256SUMS
)
```

The tree must be clean at the release commit. Review the FFmpeg configuration
and confirm that GPL and the pinned static `libx264` remain enabled while
version3, nonfree, and `libx265` remain disabled. Also verify the x264 pin:

```sh
(cd Vendor/x264 && shasum -a 256 -c checksums/SHA256SUMS)
```

`archive.sh` and `export.sh` repeat the build-manifest check and also verify the
pinned SHA-256 values for the exact FFmpeg and x264 source archives, FFmpeg
detached signature, and local patch before packaging. A freshly generated
self-check alone is not accepted as proof of corresponding-source identity.

## 2. Create the Release archive

Use the exact identity label printed by `security find-identity`:

```sh
export DEVELOPMENT_TEAM=ABCDE12345
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example (ABCDE12345)'
./Scripts/archive.sh
```

The script creates `.build/Release/Resizer.xcarchive`, forces `arm64` and
`x86_64`, disables coverage instrumentation, and verifies the app and both
nested FFmpeg tools separately. It never uses `codesign --deep`.

## 3. Export and create the DMG

Keep the same signing environment:

```sh
./Scripts/export.sh
```

The output names include the app version and build number:

```text
.build/Release/Resizer-1.0-1.dmg
.build/Release/Resizer-1.0-1-source.tar.xz
```

The DMG contains:

- `Resizer.app`;
- an `/Applications` symlink;
- short installation instructions;
- third-party notices;
- the same version-matched corresponding-source archive produced beside the DMG.

The source bundle contains the complete Resizer application and test source,
Xcode project and scripts for that version, plus the pinned FFmpeg and x264
sources, local patch, exact toolchain script and support shim,
configuration/capability reports, licenses, checksum manifests, and helper
entitlements. This lets the DMG be distributed by itself while keeping the
corresponding source available to its recipient.

## 4. Notarize and staple

This is an external Apple service operation. Run it only for an approved
release candidate:

```sh
DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=Resizer-notary \
  ./Scripts/notarize.sh .build/Release/Resizer-1.0-1.dmg
```

The script accepts only a Keychain profile, waits for the exact `Accepted`
status, stores submission evidence under `.build/Release/notary`, staples the
ticket, validates it, and asks Gatekeeper to assess the DMG. It does not use
`notarytool --force`.

Stapling changes the DMG bytes, so checksums created before this step are not
release checksums.

## 5. Verify and generate final checksums

```sh
DEVELOPMENT_TEAM=ABCDE12345 ./Scripts/verify-release.sh \
  .build/Release/Resizer-1.0-1.dmg \
  .build/Release/Resizer-1.0-1-source.tar.xz
```

The verifier checks:

- DMG integrity, Developer ID authority, notarization ticket, and Gatekeeper;
- read-only mounting and the expected payload layout;
- strict app/helper signatures, secure timestamps, the expected single Team ID,
  Hardened Runtime, and entitlements;
- Universal 2 app, `ffmpeg`, and `ffprobe` binaries;
- system-only dynamic linkage and executable modes;
- bundle identity, version, build, and macOS 14 deployment target;
- absence of release coverage instrumentation;
- bundled GPL/libx264 notices and GPL/LGPL license texts;
- the version-matched complete source manifest, required application source,
  and original pinned FFmpeg/x264 source/signature/patch checksums.

Only after all checks pass does it write `.build/Release/SHA256SUMS` for the
post-stapling DMG and source archive.
Starting archive, export, notarization, or verification invalidates an older
manifest so a failed attempt cannot leave stale checksums beside a new candidate.

The helper executables use `com.apple.security.inherit` and must not be run
directly from Terminal. Functional testing must launch them through the
sandboxed application.

## 6. Manual clean-install smoke test

Use another Mac or a clean user account and transfer the DMG through the same
download channel testers will use. Do not remove quarantine attributes.

1. Open the DMG and drag Resizer to Applications.
2. Confirm the first-launch Gatekeeper dialog identifies the developer and does
   not require a privacy/security bypass.
3. Import one H.264 and one supported SDR HEVC video together.
4. Complete both queue jobs and play both resulting MP4 files.
5. Confirm progress, results, Finder reveal, retry, and normal quit.
6. Compare source hashes before and after; originals must be unchanged.
7. Confirm no `.partial.mp4` remains after success, cancel, or failure.
8. Repeat the smoke encode on Intel hardware or under Rosetta.

Save the release commit, notary submission result/log, final checksum manifest,
and manual-test record. Publishing the DMG or creating a GitHub Release is a
separate explicitly authorized operation.

## Local structural rehearsal

When no Developer ID certificate is installed, the packaging layout can be
tested with an explicitly unsafe ad-hoc mode:

```sh
export RESIZER_RELEASE_ROOT=.build/Release-AdHoc
export RESIZER_SIGNING_MODE=adhoc
export RESIZER_ALLOW_AD_HOC=1
./Scripts/archive.sh
./Scripts/export.sh
RESIZER_ALLOW_UNNOTARIZED=1 \
  ./Scripts/verify-release.sh \
    .build/Release-AdHoc/Resizer-1.0-1.dmg \
    .build/Release-AdHoc/Resizer-1.0-1-source.tar.xz
```

This mode skips Developer ID, notarization, Gatekeeper, and final release
checksums. Its output must never be sent to testers.
