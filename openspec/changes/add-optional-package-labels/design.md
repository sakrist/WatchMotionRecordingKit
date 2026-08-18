## Package shape

The optional annotation asset is at the package root and follows the existing
session-derived naming rule:

```text
<uuid>.mmrec/
  <uuid>.device-motion.bin
  <uuid>.raw-accelerometer.bin
  <uuid>.watch.json
  <uuid>.labels.json              # optional
```

`RecordingPackageLayout` recognizes only this exact filename for the package
UUID. `RecordingPackageDescriptor` exposes an optional labels URL and continues
to reject any other visible unknown asset or nested visible directory. Labels
are annotation data, not a capture/media extension: their presence does not
change the package's core/extended recording profile.

The descriptor validates filesystem shape and file identity only. It does not
make a core package invalid because the optional labels JSON is malformed. A
separate label-schema reader validates its contents when a consumer needs them.

## Labels JSON v1

```json
{
  "formatVersion": 1,
  "sessionID": "<uuid>",
  "labels": [
    {
      "label": "strike",
      "startIndex": 45934,
      "endIndex": 46013,
      "startTimestampUnixMicroseconds": 1777546234708000,
      "endTimestampUnixMicroseconds": 1777546235103000
    }
  ]
}
```

The file is omitted until a reviewer has labels to export. It is the only
authoritative label set for that package; no revision graph, author identity,
or cross-user merge behavior exists.

V1 validation rules are:

- `formatVersion` is integer `1` and `sessionID` is the package UUID.
- `labels` is chronological and non-overlapping.
- Every label value is `strike`.
- Every range is inclusive and exactly 80 canonical 200 Hz device-motion
  samples (`endIndex - startIndex + 1 == 80`).
- The stored indexes are in range and each stored timestamp exactly matches the
  corresponding decoded device-motion record.
- Impact is not stored separately: the source interval is
  `impactIndex - 40 ... impactIndex + 39`, so `endIndex - 39` is impact.

The schema deliberately has no hash, confidence, provenance, reviewer, note,
rating, revision, or identifier field. `left-strike` is a future label/model
contract change, not a v1 alias.

## Consumer behavior

Every package consumer preserves a recognized labels file byte-for-byte through
import, local persistence, backup, restore, and sharing, even if it does not
yet display labels. It does not create the file automatically.

Label-aware review tools may parse it into editable state. If parsing or
semantic validation fails, they open the core recording, ignore labels, and
present a warning. Training fails closed: a package presented as labeled but
with invalid labels is not a training source. An unlabeled package remains
valid and simply has no annotations.

The first review workflow downloads exactly `<uuid>.labels.json`; the reviewer
manually puts it in the matching package root. No ZIP rewrite or browser
filesystem mutation is needed in this MVP.
