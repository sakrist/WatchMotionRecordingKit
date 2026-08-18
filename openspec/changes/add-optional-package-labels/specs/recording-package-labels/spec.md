## ADDED Requirements

### Requirement: Optional package labels asset

A `<uuid>.mmrec` package MAY contain exactly one root-level
`<uuid>.labels.json` asset whose UUID-derived name matches the package. Its
absence SHALL NOT invalidate the required core recording assets. The shared
package descriptor SHALL recognize this exact optional asset and SHALL continue
to reject any other visible unknown asset.

#### Scenario: A package has no labels

- **WHEN** a package contains only valid required core assets
- **THEN** the descriptor accepts it and exposes no labels URL

#### Scenario: A package has matching labels

- **WHEN** a package includes one regular file named `<uuid>.labels.json` for
  its own UUID
- **THEN** the descriptor accepts it and exposes its labels URL

#### Scenario: A package has an unsupported visible asset

- **WHEN** a package includes a visible file other than a recognized
  session-derived package asset
- **THEN** the descriptor rejects the package shape

### Requirement: Labels do not change recording profile

The optional labels asset SHALL be non-core annotation data. Its presence alone
SHALL NOT change a package's core or extended recording profile.

#### Scenario: Labels are added to a core recording

- **WHEN** labels are added to a package with only required core recording
  assets
- **THEN** it remains a core-profile recording package

### Requirement: Labels JSON v1

Labels JSON v1 SHALL use camelCase `formatVersion`, `sessionID`, and `labels`
fields. It SHALL contain only sorted, non-overlapping inclusive canonical
device-motion ranges. Each v1 range SHALL have label `strike`, start/end
indexes, and exact Unix-microsecond timestamps for those endpoints; its
inclusive range SHALL be exactly 80 samples.

#### Scenario: A valid labels file is read

- **WHEN** JSON v1 has the package UUID and valid chronological `strike` ranges
  whose indexes and endpoint timestamps match decoded device-motion records
- **THEN** a label-aware consumer accepts the labels

#### Scenario: A labels file is invalid

- **WHEN** the labels JSON is malformed, has another UUID, has unsupported
  labels, overlapping/unsorted ranges, a non-80-sample range, or coordinates
  that do not match the decoded device-motion stream
- **THEN** the core recording remains usable and the label-aware consumer
  ignores the labels with a warning

### Requirement: Labels asset preservation

Package consumers SHALL preserve a recognized optional labels asset byte-for-
byte through import, local storage, backup, restore, and sharing, whether or
not their current interface displays labels.

#### Scenario: A package is transferred by a non-label UI

- **WHEN** a consumer imports and later exports or transfers a package that
  includes labels
- **THEN** the resulting package contains the same labels file bytes
