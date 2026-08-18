## Why

Reviewed strike labels must travel with their recording rather than depend on a
separate CSV file or conversion step. The shared package contract needs one
small optional asset that every consumer can recognize and preserve, while
unlabeled recordings remain completely valid.

## Scope

- Define the optional root-level `<uuid>.labels.json` recording-package asset.
- Define JSON v1 for reviewed canonical device-motion label ranges.
- Require shared package consumers to recognize and preserve that asset without
  treating an invalid labels file as a broken core recording.
- Coordinate the IMU analyzer export/review hand-off and CNN training reader.

## Non-goals

- Do not make Watch capture create labels.
- Do not add multi-reviewer editing, revisions, provenance, confidence, hashes,
  quality scoring, or package rewriting.
- Do not change the binary stream headers, record layouts, capture rates, or
  required core assets.
- Do not make all unknown visible files acceptable; only the exact labels asset
  is added to the package contract.

## Proposed contract

A package may contain exactly one optional `<uuid>.labels.json` file at its
root. Its absence remains valid. JSON v1 contains the package UUID and sorted,
non-overlapping inclusive canonical 200 Hz device-motion ranges. Each v1 range
is exactly 80 samples, contains both index and Unix-microsecond timestamps at
each endpoint, and has the only supported label value, `strike`. Its impact is
implicit: it is the right-hand central sample (`endIndex - 39`).

Consumers recognize the asset by its exact session-derived name. They preserve
its bytes through package import, storage, backup, restore, and sharing even
when they do not present or edit labels. A malformed or mismatched labels file
does not invalidate the recording core; label-aware consumers ignore it with a
warning, while training rejects it as a labeled source.

## Impact

- `WatchMotionRecordingKit`: package layout, descriptor, public documentation,
  and tests.
- `imu-analysis-tool`: load/review/export the shared file manually; no CSV
  bridge.
- `watch-strike-cnn`: consume valid embedded labels directly for native-200-Hz
  training.
