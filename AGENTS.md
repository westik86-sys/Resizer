# Project context

- This repository is for a native macOS utility that creates smaller, compatible video copies through bundled FFmpeg tools.
- Processing is local-first: application media is not uploaded and the product does not require network access.
- Treat every input file as immutable. The original must never be modified or overwritten.
- The happy path is: select or drop video, probe it, choose Quick or bounded Flexible settings, choose an output folder, transcode with visible progress, validate the temporary result, then either publish a smaller final copy or return a neutral no-benefit result.
- [`PLAN.md`](PLAN.md) is the complete source of product and technical requirements. Keep this file concise and consult the plan before every stage. If `PLAN.md` is unavailable, stop and request it rather than guessing.

# MVP boundaries

- The first vertical slice handles one MOV or MP4: bundled `ffprobe`, one fixed H.264/AAC encode, machine-readable progress, cancellation, temporary MP4 output, validation with `ffprobe`, final commit, and before/after sizes.
- The public MVP adds multi-file import, a sequential queue, a native Quick/Flexible selector, a secondary `compactRetry` action from the immutable original, safe output naming, progress/ETA, cancel/retry, completed and `NoBenefit` results, notifications, and FFmpeg version/license disclosure.
- Quick deterministically uses HEVC VideoToolbox Main10 quality `0.70` for confirmed >8-bit SDR sources and H.264 VideoToolbox quality `0.75` otherwise, at most 1920x1080 and 30 FPS, with optional AAC 128 kbit/s. Flexible exposes only bounded quality `0.30...0.90`, source/1080p/720p/480p resolution, source/60/30/24 FPS, and keep/remove audio while retaining the same source-derived codec policy. `compactRetry` uses HEVC quality `0.60` or H.264 quality `0.45`, at most 1280x720 and 24 FPS, and inherits the Quick audio choice. No mode may upscale resolution or frame rate.
- Do not expose arbitrary FFmpeg flags, manual codec/container selection, target size, video bitrate, audio bitrate, or metadata policy. Quick, Flexible, and `compactRetry` remain closed, typed product policies; `compactRetry` is available only as an explicit secondary action and always re-encodes the original, never the first result.
- Do not add target-size encoding, arbitrary FFmpeg flags, editing tools, extra codecs or containers, persistent history, pause/resume, cloud/accounts, Finder extensions, watch folders, full HDR handling, or complex stream management without a separate product decision.
- Do not turn the MVP into a universal FFmpeg GUI or a video editor.

# Architecture rules

- SwiftUI views never launch or own `Process` instances.
- Domain must not import SwiftUI, AppKit, or `Foundation.Process`; keep domain models typed, immutable where practical, and `Sendable`.
- The Application coordinator owns the workflow and the single-source-of-truth `JobState`, including valid transitions and `probe -> captured typed recipe -> preflight -> encode -> validate -> commit/no-benefit`.
- Infrastructure owns `ProcessRunner`, `FFmpegRunner`, `FFprobeClient`, parsers, file access, diagnostic storage, and output planning.
- UI models run on `MainActor`. Isolate coordinators and other long-lived concurrent services with actors.
- Perform dependency injection in the composition root. Do not add global singletons or a service locator.
- Represent Quick, Flexible, and `compactRetry` encoding policies with validated, typed models. Represent FFmpeg arguments only as `[String]`.

# FFmpeg and process safety

- Production code uses only bundled `ffmpeg` and `ffprobe`; never depend on Homebrew, MacPorts, or `PATH`.
- Launch executables directly with `Process.executableURL` and `Process.arguments`. Never use `/bin/sh -c`, `bash -c`, or shell-command concatenation.
- Drain stdout and stderr concurrently. Keep stderr in a bounded diagnostic buffer.
- Read progress from `-progress pipe:1`; do not parse human-readable stderr as progress.
- Cancellation must attempt graceful `q\n`, then signal fallbacks, wait for process and both pipes to finish, and avoid orphan processes.
- Never accept arbitrary user-provided FFmpeg flags.
- Detect and cache the bundled build's actual capabilities before admitting a recipe or launching FFmpeg.

# File safety and sandbox

- Input is immutable, including when the user asks to overwrite it.
- FFmpeg never receives the final output URL. Write to a unique per-job temporary file that preserves the real extension, such as `.partial.mp4`.
- Publish final output only after exit code handling, EOF from both pipes, successful `ffprobe` validation of the temporary result, and proof that it is smaller than the input.
- If a validated temporary result is not smaller than the input, publish no final file, release only that job's temporary, and finish with neutral `NoBenefit`; this is not an encoding failure.
- On cancellation or failure, remove only the temporary file belonging to that job; never use broad cleanup globs.
- Reject any plan that could overwrite or alias the input path.
- Keep security-scoped access alive through encode, validation, and final commit or no-benefit cleanup.
- Do not add unnecessary sandbox or network entitlements.
- Treat paths and filenames as private in logs; keep diagnostics bounded and do not enable FFmpeg reports by default.

# Licensing and distribution

- The proposed FFmpeg default is an LGPL-only reproducible build.
- Never silently enable `--enable-gpl`, `--enable-nonfree`, `libx264`, or `libx265`. Changing the license profile requires a separate explicit decision.
- Preserve the FFmpeg source revision/archive checksum, complete build configuration, patches, relevant source, build instructions, capabilities, and notices needed for reproducibility and compliance.
- Do not change signing, entitlements, bundle ID, deployment target, architecture policy, or distribution channel during an ordinary feature task.

# Testing and verification

- Unit-test the state machine, probe/progress parsers, command builder, Quick/Flexible/`compactRetry` policies, audio removal, `NoBenefit`, naming, and output policy.
- Use a deterministic `ProcessHarness` for simultaneous pipes, large output, exit codes, graceful cancellation, ignored signals, and cancellation races.
- Cover an integration flow of `probe -> transcode -> probe`, including temporary-file cleanup and unavailable capabilities.
- Tests must not depend on Homebrew, `PATH`, or personal media files.
- Finish each stage with the smallest relevant build and test set, and report the exact commands and results.
- Build with `./Scripts/build.sh` and run unit tests with `./Scripts/test.sh`.

# Working rules

- Read `PLAN.md`, all applicable `AGENTS.md` files, `git status`, project structure, and existing build/test scripts before changing files.
- Preserve all uncommitted user work. Do not revert, delete, or overwrite unrelated changes.
- Do not add third-party dependencies without demonstrated need and user confirmation.
- Do not commit, push, release, notarize, or publish without a direct request.
- Work only within the requested PLAN stage; do not advance automatically to the next stage.
- Do not hide, weaken, or work around failing tests.
- Report blockers, remaining risks, and any manual verification still required.
