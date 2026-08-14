# Decisions

## 2026-08-14 — Identify and cancel recording startup by session

Watch recording lifecycle uses explicit idle, starting, recording, and stopping
phases, with the session UUID carried by every non-idle phase. Public start/stop
operations and asynchronous session setup transition that state on the main
actor. Stop during startup invalidates and cancels the task before stopping
resources and removing incomplete files; normal drain, finalization, and transfer
begin only after startup reaches recording.

Task cancellation is not treated as the sole safety boundary because microphone
and WatchConnectivity callbacks can resume later. Every suspended startup step
also validates its session UUID, and an accepted phone-prepare reply received
after cancellation is balanced with a stop command. This prevents stale work from
starting sensors or cleaning up a replacement session.

The unreleased package also removes workspace-unused recording-name state,
legacy start/stop aliases, the single-stream timing convenience wrapper, and
unreachable internal capture errors instead of maintaining compatibility code.

## 2026-08-13 — Publish queued transfer state separately from pending sessions

The coordinator exposes `isSyncing` from WatchConnectivity's outstanding file
queue and retains `pendingSyncSessionCount` as the count of locally stored
sessions missing at least one success marker. The Watch UI distinguishes active
sync from waiting files and publishes both values with recording state through
application context. This is coarse state, not byte-level progress.
The completion callback supplies the remaining queue count with the completed
transfer excluded because the outstanding list can still contain it during the
delegate callback. The final file therefore clears active sync immediately.

## 2026-08-09 — Use `.mmrec` for recording package directories

The canonical package directory is `<uuid>.mmrec`. The extension is a
container-level identifier only; the binary and JSON contracts are unchanged.
The shared descriptor accepts `.mmrec` and rejects the previous `.recording`
package name.

## 2026-08-06 — Use the UUID directly as the recording filename stem

New recording assets use `<uuid>.device-motion.bin`,
`<uuid>.raw-accelerometer.bin`, and the matching sidecars. The package directory
is `<uuid>.mmrec`. The filename parser still recognizes the older
`recording_<uuid>` loose-file form for development recordings, but writers never
emit that prefix.

## 2026-08-05 — Local-only recording never waits for scheduled start

`coordinatesWithPhoneRecording = false` is an immediate local-start policy.
It skips iPhone preparation and always calculates zero scheduled wait, regardless
of the configured lead-time value. Apps must still start any required HealthKit
workout before calling the coordinator; that platform prerequisite is outside
the package's synchronization policy.

## 2026-08-04 — Split the coordinator at concrete responsibility boundaries

`WatchRecordingCoordinator` remains the stable public facade for both apps.
Its implementation is divided into public coordination, recording-session
lifecycle, and ordered Core Motion processing. Live telemetry and optional
audio use small concrete helpers with no protocol layer.

This is a behavior-preserving organization change: public APIs, binary bytes,
sensor rates, transfer semantics, and threading order remain unchanged. The
package deliberately keeps one serial motion pipeline rather than introducing
multiple actors or services whose synchronization would be harder to audit.

## 2026-08-04 — Keep recording order documented beside the package

The complete startup, active-recording, shutdown, and failure order is maintained
in `docs/RECORDING_FLOW.md`. Code comments explain ordering constraints and
threading invariants rather than restating individual Swift expressions. Changes
to recording order, sensor rates, buffering, or failure cleanup must update the
flow document in the same change.
