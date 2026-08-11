# WatchMotionRecordingKit

Reusable Apple Watch motion-recording primitives.

## Start Here

For a plain-language explanation of what happens after the user taps Record,
including an ordered flow diagram, see [Recording Flow](docs/RECORDING_FLOW.md).

## What It Contains

- Recording-control messages and scheduled-start replies
- Shared phone and Watch metadata contracts
- Automatic native batched capture at 200 Hz device motion and 800 Hz raw acceleration
- Shared uptime-to-Unix timestamp projection with scheduled-start gating
- Versioned fixed-record binary codecs, integrity hashes, and writers
- WatchConnectivity transfer and retained pending-session coordination

## Internal Structure

`WatchRecordingCoordinator` is the public facade used by app code. It owns
published state, start/stop intent, and transfer commands. Session setup and
cleanup live in a focused coordinator extension, while Core Motion callbacks,
startup validation, timestamp gating, and ordered writes stay together in the
motion-capture extension so their sequencing remains visible in one place.

Live graph decimation is owned by a small value-type buffer and optional audio
capture is owned by a dedicated helper. These are concrete internal types, not
public protocols. The split keeps the shared API stable and leaves room to
replace one capability without turning the package into a framework hierarchy.

## Capture Contract

Recording is available only when `CMBatchedSensorManager` supports both device motion and raw acceleration. The app owns HealthKit authorization and workout lifecycle and must wait for the workout to reach `.running` before calling `startRecording()`.

Each successful motion recording produces one logical three-file asset set:

```text
<session-id>.device-motion.bin
<session-id>.raw-accelerometer.bin
<session-id>.watch.json
```

When `WatchRecordingConfiguration.recordsAudio` is enabled, the same session
also produces `<session-id>.m4a`. Audio is transferred with the
motion assets but is intentionally not part of the motion sidecar because it
has no binary sample-count or hash contract in this package.

Both sensor files have explicit 64-byte little-endian headers. The Watch generates one UUID per recording, uses its lowercase string form for asset names and metadata, and encodes its native 16 bytes in both headers. Device-motion records are 60 bytes and contain a Unix-microsecond timestamp, user acceleration, rotation rate, gravity, and quaternion as Float32 values. Raw-accelerometer records are 20 bytes and contain a timestamp plus three acceleration components as Float32 values. The streams retain their independent timestamps and are never assumed to be row-aligned.

The metadata sidecar names both files and records their finalized byte sizes, SHA-256 hashes, format versions, actual frequencies, and sample counts. `applicationPayloads` remains available for app-owned sidecar data such as strike ratings.

The coordinator buffers accepted samples for about one second per stream before
writing, then forces any final partial batch during stop. Stopping capture
stops both batched sources, drains delivered writes, rewrites finalized headers,
writes the sidecar, and only then queues the complete asset set. Pending-transfer
markers are tracked per file while retention and retry grouping remain
session-based.

## Binary Format

**Header** (64 bytes, little-endian):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | Magic (`WMRDM001` or `WMRRA001`) |
| 8 | 2 | Format version (`1`) |
| 10 | 2 | Record size in bytes |
| 12 | 8 | Sample count |
| 20 | 16 | Session UUID (RFC 4122, raw) |
| 36 | 2 | Actual frequency (Hz) |
| 38 | 26 | Reserved (zero) |

**Device-motion record** (60 bytes):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | Timestamp (Int64, Unix microseconds) |
| 8 | 4 | userAcceleration.x (Float32) |
| 12 | 4 | userAcceleration.y (Float32) |
| 16 | 4 | userAcceleration.z (Float32) |
| 20 | 4 | rotationRate.x (Float32) |
| 24 | 4 | rotationRate.y (Float32) |
| 28 | 4 | rotationRate.z (Float32) |
| 32 | 4 | gravity.x (Float32) |
| 36 | 4 | gravity.y (Float32) |
| 40 | 4 | gravity.z (Float32) |
| 44 | 4 | quaternion.w (Float32) |
| 48 | 4 | quaternion.x (Float32) |
| 52 | 4 | quaternion.y (Float32) |
| 56 | 4 | quaternion.z (Float32) |

**Raw-accelerometer record** (20 bytes):

| Offset | Size | Field |
|--------|------|-------|
| 0 | 8 | Timestamp (Int64, Unix microseconds) |
| 8 | 4 | rawAcceleration.x (Float32) |
| 12 | 4 | rawAcceleration.y (Float32) |
| 16 | 4 | rawAcceleration.z (Float32) |

Non-finite values and timestamp regression fail the active recording.

## What It Does Not Contain

- SwiftUI views
- HealthKit workout management
- App-specific analysis, persistence, or interface policy

## Recording package

The shared package contract wraps one finalized session in a
`<uuid>.mmrec` directory. Its required core files are the two
binary streams and `<uuid>.watch.json`; audio, video, and
`<uuid>.phone.json` are optional extensions, with phone metadata
required whenever video is present. `RecordingPackageLayout` and
`RecordingPackageDescriptor` provide the canonical names and filesystem shape
validation. They intentionally do not replace the existing binary readers or
JSON validators.
