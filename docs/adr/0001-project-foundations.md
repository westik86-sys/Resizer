# ADR 0001: Project foundations

- Status: Accepted for bootstrap; codec defaults remain proposed
- Date: 2026-07-13
- Source of truth: [`PLAN.md`](../../PLAN.md)

## Context

The product is a native macOS utility for people who need a smaller, broadly compatible video without learning FFmpeg or uploading media to a service. Its promise is a simple preset-led workflow that creates a verified copy while leaving the original unchanged.

The first engineering target is a narrow vertical slice rather than the full public MVP: select one MOV or MP4, probe it with bundled `ffprobe`, run one fixed H.264/AAC transcode with progress and cancellation, validate the temporary MP4 with `ffprobe`, commit it to a safe final name, and show the before/after sizes. This must establish the risky process, file-access, and output-safety boundaries before complex UI or queue work.

This ADR records the foundations confirmed for bootstrap and the codec recommendations still awaiting validation. It authorizes only the minimal bootstrap stage; it does not authorize FFmpeg acquisition, a toolchain spike, product UI, or release actions.

## Accepted product constraints

- Processing is local-first; application media is not uploaded and the app does not need network access.
- The original input is immutable and must never be modified or overwritten.
- The product is an opinionated compressor, not a universal FFmpeg GUI or video editor.
- The single-file vertical slice must precede complex UI and queue implementation.
- The public MVP uses a sequential queue with at most one active FFmpeg process.
- SwiftUI and FFmpeg are separated by a CLI `Process` boundary; the app does not link directly to `libav*` for the MVP.
- Encoding options are validated typed models; users cannot supply arbitrary CLI flags.

## Accepted bootstrap foundations

The user confirmed these values on 2026-07-13:

| Area | Accepted value |
|---|---|
| Application name | Resizer |
| Bundle identifier | `com.example.Resizer` |
| Scheme | `Resizer` |
| Minimum OS | macOS 14+ |
| Language | Swift 6 with strict concurrency checking |
| UI | SwiftUI |
| Public architecture | Universal 2 (`arm64` and `x86_64`) |
| Sandboxing | App Sandbox enabled from the start |
| Initial distribution | Direct Developer ID beta with Hardened Runtime and notarization |
| FFmpeg packaging | Reproducibly built bundled `ffmpeg` and `ffprobe` CLI executables |
| FFmpeg license profile | LGPL-only; no `--enable-gpl` or `--enable-nonfree` |

No signing identity, Team ID, certificate, or notarization credential is stored in the project. Those operational values belong to the release stage.

## Proposed codec defaults

These remain recommendations from `PLAN.md` and must be validated against the eventual bundled FFmpeg capabilities:

| Area | Proposed default |
|---|---|
| Video encoder | `h264_videotoolbox` |
| Audio encoder | AAC |
| Output | MP4 with `faststart` |

The proposed repository architecture is a SwiftUI app target plus a local `CompressionCore` package separated into Domain, Application, and Infrastructure, with UI dependencies composed at the application composition root.

## Open decisions

The following still require explicit confirmation or evidence before they become release commitments:

- Legal/compliance review of the confirmed LGPL-only position and any H.264 patent considerations; any move to GPL components is a separate decision.
- Exact FFmpeg source revision, feature set, build flags, checksums, notices, and evidence that the proposed codec defaults are present.
- MVP policy for multiple audio tracks, subtitles, and chapters.
- Localization scope: Russian and English, one language only, or another set.

## Alternatives considered

### Universal FFmpeg GUI

Rejected for the MVP because arbitrary codecs, containers, filters, and CLI flags enlarge the product surface, weaken validation, and increase safety and support risk. The product stays preset-led.

### Direct `libav*` integration

Deferred in favor of bundled CLI executables. A process boundary isolates ordinary FFmpeg crashes, avoids C bridging and ABI coupling, and makes progress, cancellation, upgrades, and harness testing more tractable. It does not remove licensing obligations.

### Homebrew, MacPorts, or `PATH` FFmpeg

Rejected for production because versions, features, architectures, paths, and licenses would be outside the application's control. Tests may inject controlled executable URLs, but production resolves only app-bundled tools.

### GPL FFmpeg with `libx264`/`libx265`

Not selected. An LGPL-only build using VideoToolbox is the proposed baseline. GPL or nonfree components require an explicit product and legal decision and a new ADR.

### Encode directly to the final output

Rejected because exit code alone is insufficient proof of a valid result. Each job writes a unique temporary file with the correct extension, drains both pipes, validates it with `ffprobe`, and only then performs the final filesystem commit.

### Parallel queue

Rejected for the MVP. One active encode simplifies state transitions, cancellation, resource use, and error isolation while the core workflow is established.

### arm64-only public distribution

Not selected. Universal 2 is required for the public build; arm64-only remains acceptable for local development and internal prototypes.

## Consequences

- The app must carry, sign, version, and expose the capabilities and licenses of its own `ffmpeg` and `ffprobe` executables.
- Domain remains independent of SwiftUI, AppKit, and `Foundation.Process`; UI models run on `MainActor`, while the coordinator and long-lived process services use actor isolation.
- `JobState` is the single workflow state source, and the Application coordinator serializes `probe -> preflight -> encode -> validate -> commit` plus cancellation races.
- Process infrastructure must bind an identity-checked reserved file to FFmpeg stdout, drain progress and diagnostics from stderr, parse `-progress pipe:2`, and implement graceful cancellation with signal fallbacks and EOF synchronization.
- Sandbox file access must remain active through transcode, validation, and final commit. No network entitlement is expected.
- Output planning must prevent input aliasing and collisions. Failure or cancellation cleans only the known job's temporary output.
- Reproducible FFmpeg provenance, checksums, configure flags, patches, source/build instructions, capabilities, and notices become release artifacts rather than optional documentation.
- The first implementation work must remain a narrow, testable stage; later codecs, target-size mode, editing, persistence, and advanced stream handling need separate decisions.

## Validation required

Before or during the relevant PLAN stages, validate all of the following:

- Keep the confirmed identity, macOS 14+, Universal 2, App Sandbox, Developer ID channel, and LGPL-only profile stable unless a new explicit decision supersedes this ADR.
- Bootstrap produces a minimal SwiftUI application and empty test target that build with documented shell-first commands; no commands are assumed before that stage.
- A signed sandbox spike proves bundled `ffmpeg` and `ffprobe` can access user-selected input and output-folder resources for the full security-scope lifetime.
- Record the FFmpeg source revision and checksum, exact configure flags, build outputs for required architectures, `-version`, `-buildconf`, and actual encoder/decoder/muxer/protocol lists.
- Prove the required `h264_videotoolbox`, AAC, and MP4 capabilities exist before showing dependent settings.
- Unit tests cover state transitions, JSON/rational parsing, progress parsing, typed command construction, presets, output naming, and collision/input-overwrite policy.
- A deterministic `ProcessHarness` proves simultaneous pipe draining, bounded large output, exit handling, graceful and forced cancellation, ignored signals, and completion/cancel races without orphan processes.
- An integration fixture completes `probe -> transcode -> probe`, validates the temporary result, commits it, and cleans only its own temp file on failure or cancellation.
- Release validation eventually covers architectures, nested signing, entitlements, codesign, notarization, Gatekeeper, bundled-tool execution, QuickTime/Quick Look playback, and license/source completeness.
