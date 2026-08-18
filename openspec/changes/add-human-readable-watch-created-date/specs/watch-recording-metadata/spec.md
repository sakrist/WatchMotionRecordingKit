## ADDED Requirements

### Requirement: Human-readable Watch sidecar creation date

Every newly encoded Watch recording metadata sidecar SHALL include `created` as
an ISO 8601 UTC string representing the same instant as `createdUnix`.

#### Scenario: New sidecar

- **WHEN** the Watch writes a recording metadata sidecar
- **THEN** it includes numeric `createdUnix` and ISO 8601 `created`

#### Scenario: Existing sidecar

- **WHEN** a sidecar has `createdUnix` but no `created`
- **THEN** the shared metadata contract decodes it and derives `created` from
  `createdUnix`
