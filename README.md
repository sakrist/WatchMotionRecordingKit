# WatchMotionRecordingKit

Reusable Apple Watch motion-recording primitives.

## What It Contains

- Recording-control messages and scheduled-start replies
- Shared phone and Watch metadata contracts
- Automatic native batched capture at 200 Hz device motion and 800 Hz raw acceleration
- Shared uptime-to-Unix timestamp projection with scheduled-start gating
- Versioned fixed-record binary codecs, quantization, integrity hashes, and writers
- WatchConnectivity transfer and retained pending-session coordination

## Capture Contract

Recording is available only when `CMBatchedSensorManager` supports both device motion and raw acceleration. The app owns HealthKit authorization and workout lifecycle and must wait for the workout to reach `.running` before calling `startRecording()`.

Each successful motion recording produces one logical three-file asset set:

```text
recording_<session-id>.device-motion.bin
recording_<session-id>.raw-accelerometer.bin
recording_<session-id>.watch.json
```

Both sensor files have explicit 64-byte little-endian version-1 headers. The Watch generates one UUID per recording, uses its lowercase string form for asset names and metadata, and encodes its native 16 bytes in both headers. Device-motion records are 34 bytes and contain projected Unix microseconds, user acceleration, rotation rate, gravity, and quaternion. Raw-accelerometer records are 14 bytes and contain projected Unix microseconds plus acceleration including gravity. The streams retain their independent timestamps and are never assumed to be row-aligned. Timestamp-based development identifiers are intentionally unsupported.

The metadata sidecar names both files and records their finalized byte sizes, SHA-256 hashes, format versions, actual frequencies, sample counts, and saturation counts. `applicationPayloads` remains available for app-owned sidecar data such as strike ratings.

Stopping capture stops both batched sources, drains delivered writes, rewrites finalized headers, writes the sidecar, and only then queues the complete asset set. Pending-transfer markers are tracked per file while retention and retry grouping remain session-based.

## Binary Constants

- Device-motion magic: `WMRDM001`
- Raw-accelerometer magic: `WMRRA001`
- Writer format version: `2` (version `1` remains readable)
- User acceleration: `64 / 32767` g/count
- Rotation rate: `64 / 32767` rad/s/count
- Gravity and quaternion: `1 / 32767` unit/count
- Raw acceleration: `256 / 32767` g/count

Finite out-of-range values clamp to `-32767...32767` and increment the relevant file saturation count. `Int16.min` is reserved and rejected. Non-finite values and timestamp regression fail the active recording.

## What It Does Not Contain

- SwiftUI views
- HealthKit workout management
- App-specific analysis, persistence, or interface policy
