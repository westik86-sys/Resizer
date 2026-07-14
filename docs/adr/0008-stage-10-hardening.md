# ADR 0008: Stage 10 safety and product hardening

- Status: Accepted
- Date: 2026-07-14
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

The stage-9 FIFO queue completed the public MVP feature set, but the hardening
matrix still exposed release-blocking gaps: normal application termination did
not wait for child teardown, finalization could not be cancelled, and technical
diagnostics could expose selected paths. The stage also revisited whether safe
publication could be expanded beyond clone-capable storage without weakening
the descriptor-owned output contract. The product additionally needed complete
English/Russian copy, keyboard and VoiceOver behavior, and bundled license
disclosure before release work could begin.

## Decision

### Coordinated shutdown and finalization cancellation

`ApplicationLifecycleDelegate` returns `terminateLater` for a normal quit and
awaits `CompressionFeatureModel.shutdown()`. The model stops snapshot
observation and asks `JobQueueCoordinator` to stop admission, cancel the FIFO
driver and every active workflow, and wait until its workflow set is empty.
`ProcessRunner` remains responsible for graceful `q\n`, signal escalation,
process exit, and stdout/stderr EOF. Force Quit remains an operating-system
escape hatch and cannot provide cleanup guarantees.

Validation and publication are registered cancellable operations. A cancel
during validation or before the no-replace publication syscall transitions the
job through `cancelling`, releases only its reservation, and publishes no final
file. If the atomic publication syscall has already succeeded, publication is
the linearization point and completion wins a simultaneous late cancellation.

### Fail-closed clone-only publication

Resizer retains the descriptor-owned publication path. The held output
directory must report clone support before staging is created. Resizer creates
the per-job file exclusively, verifies its pathname and descriptor identity,
unlinks it, and requires the retained descriptor to have zero links. After
validation, no-replace `fclonefileat` publishes that exact anonymous descriptor
to the retained directory. An existing destination is never replaced.

A named-path fallback is rejected. `renameatx_np(..., RENAME_EXCL)` protects the
destination name but cannot bind the source operand to the already validated
descriptor; another writer could replace the source pathname after its final
identity check. Darwin provides no conditional rename-by-inode primitive.
Volumes without clone support therefore fail with a typed error before encode,
and there is no rename or copy fallback. Broadening filesystem support requires
a separate product and security decision backed by an equally strong platform
primitive.

Darwin also provides no conditional unlink-by-inode primitive. A hostile
same-user process that can write to the selected directory could therefore race
the synchronous descriptor/path identity check and immediate unlink by placing
another entry at the unpredictable per-job staging name. The window contains no
suspension point, and the retained descriptor is required to have zero links
before encode, so this does not weaken immutable-input or descriptor-bound final
publication guarantees; it remains a documented local denial-of-service/name
cleanup limitation rather than a claim of protection from mutually hostile
processes running as the same macOS user.

### Errors, diagnostics, localization, and disclosure

Filesystem and workflow failures map to typed user actions, including missing
input, unavailable output, collision, unsupported filesystem, and insufficient
storage. Primary error copy never includes a process exit code. The diagnostics
disclosure builds a bounded structured report containing app and FFmpeg
versions, license profile, workflow stage, typed reason, optional exit status,
and truncation state. Selected paths, filenames, derived output names, and
unknown common absolute paths are redacted before display or copy.

All shipped product strings have English and Russian catalog entries, including
plural forms and computed labels. Major validation, failure, and success states
receive programmatic accessibility focus; decorative imagery is hidden; metric
pairs and progress expose combined labels and values; primary queue actions
have keyboard equivalents. Settings exposes the exact bundled third-party
notice and LGPL 2.1/3 texts.

### Reproducible bundled toolchain

FFmpeg 8.1.2 is rebuilt from the pinned archive for `arm64` and `x86_64` with a
stable non-user build root, virtual prefix, compiler prefix maps, deterministic
environment, and the existing LGPL-only feature profile. Binary and report
hashes are recorded in `BUILD_SHA256SUMS`. Build output must contain no checkout
or user-home path, no GPL/nonfree/libx264/libx265 enablement, and only system
dynamic dependencies.

## Consequences

- Normal quit waits for deterministic queue and child-process teardown.
- Cancellation remains available through validation and up to the atomic
  publication boundary.
- Safe local output fails closed on volumes without clone support and preserves
  descriptor-source, no-replace publication.
- Support diagnostics remain useful while selected filenames and paths stay
  private.
- The MVP UI is available in English and Russian and exposes its bundled
  licensing materials offline.
- Developer ID archive, notarization, stapling, Gatekeeper, and clean-account
  installation remain stage 11 and are intentionally not performed here.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Application/CompressionWorkflowTests.swift`
- `ResizerTests/Application/JobQueueCoordinatorTests.swift`
- `ResizerTests/Infrastructure/SecurityScopedFileAccessTests.swift`
- `ResizerTests/UI/DiagnosticReportBuilderTests.swift`
- `ResizerTests/UI/LocalizationTests.swift`
- `ResizerUITests/ResizerUITests.swift`
- `Vendor/FFmpeg/checksums/BUILD_SHA256SUMS`
