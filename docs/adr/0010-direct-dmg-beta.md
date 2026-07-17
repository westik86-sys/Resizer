# ADR 0010: Direct notarized DMG beta

> Ordinary H.264 encoding, rate control, and licensing/source-distribution
> details are superseded by [ADR 0014](0014-libx264-gpl-toolchain.md).

- Status: Accepted for Stage 11 preparation
- Date: 2026-07-14
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

The hardened MVP is ready for distribution work, but the first testers do not
need Mac App Store or TestFlight delivery. They need one familiar disk image
that installs without bypassing Gatekeeper and keeps the bundled FFmpeg license
and corresponding-source obligations available offline.

Stage 10 intentionally left Developer ID archive, notarization, stapling,
Gatekeeper, and clean-install testing to Stage 11.

## Decision

The first beta channel is a direct compressed DMG containing `Resizer.app`, an
Applications symlink, brief installation text, third-party notices, and a
self-contained archive of the exact FFmpeg corresponding source and build
materials. The same source archive is emitted beside the DMG for optional
separate hosting.

The application and nested `ffmpeg`/`ffprobe` executables remain Universal 2,
macOS 14+, sandboxed, Hardened Runtime code. A release requires a Developer ID
Application identity, secure timestamp, notarization with credentials stored in
Keychain, ticket stapling, Gatekeeper assessment, and a sandboxed UI smoke
encode. App Store Connect, TestFlight, store provisioning, receipt handling,
and PKG installers are excluded.

Release tooling accepts operational values through environment variables but
never stores Team credentials, passwords, private keys, or notarization tokens
in the repository. The default mode fails without Developer ID. A separate
explicit ad-hoc mode exists only to exercise archive and DMG structure locally;
it skips final checksums and cannot qualify as a distributable artifact.

Nested code is verified individually without `codesign --deep`. Because the
helpers carry `com.apple.security.inherit`, static checks cover their signature,
architectures, entitlements, and linkage; functional execution occurs only as
a child of the sandboxed app.

Final checksums are generated only after signing, notarization, stapling, and
verification because stapling mutates the DMG.

## Consequences

- Testers receive a conventional drag-to-Applications DMG without App Store
  infrastructure.
- The DMG remains self-contained for FFmpeg corresponding-source access.
- An Apple Developer Program membership, Developer ID identity, Team ID, and
  Keychain notary profile remain required before external distribution.
- The permanent bundle identifier, application icon, copyright, legal review,
  Intel/Rosetta smoke test, and clean-user install remain explicit release
  gates rather than being silently changed by scripts.
- Publication or GitHub Release creation remains a separate authorized action.
