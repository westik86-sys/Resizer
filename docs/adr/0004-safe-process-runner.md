# ADR 0004: Safe asynchronous process runner

- Status: Accepted for implementation stage 4
- Date: 2026-07-13

## Context

The production probe and transcode adapters need one reusable process boundary
that launches bundled tools directly, streams both pipes without deadlock, and
can cancel a child without leaking `Foundation.Process` across actor isolation.
The boundary must remain generic: FFmpeg's graceful `q\n` command is useful,
but it is not valid behavior for every executable.

An unbounded `AsyncThrowingStream` would also undermine bounded diagnostics: a
fast child and slow consumer could retain arbitrary output in stream storage.
Process termination alone is insufficient for completion because unread bytes
may remain in either pipe after the child exits.

## Decision

Use one `ProcessRunner` actor to own every `Process`, pipe, continuation,
cancellation task, and per-execution state. Launch only through
`Process.executableURL` and `Process.arguments`; do not invoke a shell or inherit
the parent environment. `ProcessRequest` normalizes a controlled environment
with `LC_ALL=C` and `LANG=C`, and rejects NUL-containing arguments and
environment entries. An execution ID is a one-shot capability: callers create a
fresh ID for every start, never reuse it, and request cancellation only after
`start` has returned its stream. This avoids ambiguous late external cancels
without retaining an unbounded history of completed IDs in the runner. Every
start also creates a private generation token. All delayed internal callbacks
and cancellation steps must match both the public ID and this token. Cancelling
an escalation task stops it instead of advancing to the next signal.

Drain stdout and stderr independently with blocking POSIX `read(2)` calls on
detached workers. Each read returns currently available pipe data rather than
waiting for a complete fixed-size buffer, so readiness and progress events are
observable while the child is still running. Workers pass only `Data`, channel,
execution ID, and generation token back to the actor; a `Process` instance never
enters a worker.

Stage 7 extends `ProcessRequest` with a narrow alternative for stdout: an
already-created empty regular file plus its expected device/inode. The runner
opens it with `O_NOFOLLOW`, verifies identity and zero size with `fstat`, and
binds that exact descriptor to the child. No stdout bytes enter the event stream
in this mode; this is how FFmpeg writes to an atomically reserved inode without
reopening a pathname.

Publish chunks through a finite `.bufferingOldest` stream. A dropped event is a
typed failure that starts child cancellation while both workers continue to
drain. This avoids silent corruption of future machine-readable output. Retain
stderr separately in an exact-capacity tail buffer and expose whether earlier
bytes were truncated.

Finalize through one actor-owned gate only after all three facts are true:

1. the direct child has terminated;
2. streamed stdout reached EOF or a terminal read failure, or direct-file
   stdout was successfully bound;
3. stderr reached EOF or a terminal read failure.

On a normal or nonzero exit, yield exactly one terminal `ProcessResult` and then
finish the continuation. Launch, pipe-read, and event-overflow failures finish
the throwing stream with a typed error. A nonzero child exit remains a normal
terminal result.

Make cancellation input request data rather than runner behavior. A request may
close stdin or provide one bounded cancellation message; the later FFmpeg
adapter will provide `q\n`. Escalation is message and close, SIGINT, SIGTERM,
then SIGKILL with validated waits and a liveness check before every step. Set
`F_SETNOSIGPIPE` on the stdin writer so an exit/write race becomes a catchable
`EPIPE` instead of terminating Resizer. `cancel` is idempotent and does not
return until the child and both pipes have completed. Results record whether
cancellation was requested and the highest attempted step.

If the task awaiting `cancel` is itself cancelled, the runner removes only that
task's completion waiter; the actor-owned cancellation escalation continues.
This keeps task cancellation cooperative without orphaning the direct child.

The guarantee applies to the direct child. The generic runner does not claim to
own or terminate process groups or arbitrary descendants.

## Test harness

Build `Tests/ProcessHarness/main.c` as a test-only native command-line target.
`ResizerTests` depends on it and embeds it in the test bundle's Executables
directory; the app target and normal app archives do not contain it. The harness
uses direct POSIX writes, signal behavior, and watchdog alarms, with modes for
success, nonzero exit, simultaneous multi-megabyte output, literal arguments
and environment, graceful cancellation, ignored signals, cancellation races,
and delayed pipe EOF. Patterned stderr verifies exact tail ordering after
multiple ring-buffer wraps, while test-level deadlines bound stream collection
and awaited cancellation.

## Consequences

- Later FFprobe and FFmpeg adapters share the same launch, streaming,
  diagnostics, and cancellation safety rules.
- A consumer that cannot keep up receives an explicit overflow failure instead
  of incomplete output.
- Completion can be delayed beyond process exit until inherited pipe writers
  close; publishing earlier would lose output.
- Cancellation waits are configurable per request for deterministic tests and
  tool-specific graceful behavior, but arbitrary shell commands remain
  impossible.
- Descendant cleanup would require a separate process-group design and is not
  implied by this runner.

## Verification

- `./Scripts/build.sh`
- `./Scripts/test.sh`
- `ResizerTests/Infrastructure/ProcessRunnerTests.swift`
- `Tests/ProcessHarness/main.c`
