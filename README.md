# WatchMotionRecordingKit

Reusable recording primitives extracted from HurleyMetric.

## What It Contains

- Recording control message types for watch/phone coordination
- Scheduled start reply helpers
- Shared phone/watch metadata structs
- Watch-side sample timestamp projection from motion time to Unix time
- Scheduled sample gating for watch pre-roll capture

## What It Does Not Contain

- SwiftUI views
- `ObservableObject` app state
- `WCSession` transport code
- File IO or AVFoundation capture orchestration

## Intended Use

Import this package into a watch or phone app and build target-specific adapters around it:

- Use `RecordingControlMessage` and `ScheduledStartResponse` to encode/decode `WCSession` dictionaries.
- Use `WatchSampleTimingController` to convert motion timestamps into Unix timestamps and drop pre-roll samples before the agreed start time.
- Use `PhoneRecordingMetadata` and `WatchRecordingMetadata` as the shared sidecar schema.
