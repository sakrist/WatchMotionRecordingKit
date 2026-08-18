## Why

`createdUnix` is useful for calculation but inconvenient to inspect in a saved
Watch sidecar.

## What Changes

- Add `created` as an ISO 8601 UTC string to `WatchRecordingMetadata`.
- Derive it from `createdUnix` for all newly written sidecars.
- Preserve decoding of existing sidecars that contain only `createdUnix`.
