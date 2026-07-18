# ADR 0017: Downloads default and automatic Finder reveal

- Status: Accepted
- Date: 2026-07-18
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

Requiring an output-folder choice before every session adds friction to the
primary utility workflow. The product should save a verified smaller copy to a
predictable location immediately, while retaining the existing option to use a
different folder. After processing, users also need to find the actual
published files without navigating Finder manually.

The application remains sandboxed. A URL constructed for Downloads does not
carry the PowerBox grant provided by `fileImporter`, so selecting the path in
UI state alone would fail in a signed build.

## Decision

The user-domain Downloads directory is the production output default. The
composition root obtains it with `FileManager` and `.downloadsDirectory`; no
home-directory string or literal folder name is constructed. Because App
Sandbox can return this common directory through a container-owned symbolic
link, the composition root resolves that one trusted system candidate before
passing it to the file-access layer. The general workflow continues to reject
symbolic links for inputs, user-selected directories, and planned outputs. If
the system cannot resolve that directory, the existing output-folder chooser
remains the fallback. A user-selected override applies to future queue
admissions in the current app session.

The app carries the narrow
`com.apple.security.files.downloads.read-write` entitlement in addition to its
existing user-selected read/write entitlement. Bundled `ffmpeg` and `ffprobe`
retain only App Sandbox plus `com.apple.security.inherit`; output bytes continue
to flow through the exact anonymous file descriptor opened and retained by the
app. No network or broad all-files entitlement is added.
The generated app Info.plist carries a localized
`NSDownloadsFolderUsageDescription` so the first system privacy prompt explains
that Resizer saves compressed copies there.

Automatic Finder reveal is presentation behavior owned by the `MainActor`
feature model. It records newly completed output URLs synchronously while
consuming snapshots, waits until the current FIFO driver is no longer
draining, and asks `NSWorkspace` once to reveal the collected files. Repeated
or coalesced snapshots must not duplicate that side effect. `NoBenefit`,
failed, and cancelled jobs contribute no URL. A user-default preference enables
automatic reveal by default and permits opting out; the explicit Open and
Reveal actions remain available.

## Consequences

- The normal Start action is immediately available after probing because a
  production destination already exists.
- Finder opens once per drained queue rather than stealing focus after each
  file.
- The app has read/write access to the user's full Downloads folder. This is a
  deliberate, bounded sandbox expansion required for zero-prompt output.
- Safe staging, validation, no-benefit handling, no-replace publication, input
  immutability, and session-only arbitrary-folder access are unchanged.
- Release verification must require the Downloads entitlement on the app and
  continue to reject it on the helper executables.

## Verification

- Unit tests cover the injected default directory, preference default, one
  reveal after queue drain, duplicate snapshots, opt-out, non-file terminal
  outcomes, and resolution of the sandbox container link for the trusted
  system Downloads candidate.
- Signed release verification checks the app and helper entitlement allowlists.
- The clean-account smoke test confirms output is written to Downloads without
  a folder prompt and Finder selects every published result after the queue
  drains.
