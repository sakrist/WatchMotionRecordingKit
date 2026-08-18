## 1. Define the shared package asset

- [ ] 1.1 Add `labels` to the shared package asset kind, canonical filename and
  optional descriptor URL, while retaining rejection of all other unknown
  visible assets.
- [ ] 1.2 Keep labels non-core and ensure labels presence does not alter the
  recording core/extended profile classification.
- [ ] 1.3 Add focused shared Codable schema/validation support, or an equally
  shared schema contract, for labels JSON v1 without coupling malformed labels
  to core package-shape validity.

## 2. Preserve and validate correctly

- [ ] 2.1 Update package import, local storage, backup, restore, and sharing
  paths in package consumers to preserve the recognized labels file byte-for-byte.
- [ ] 2.2 Add tests for optional absence, exact asset-name recognition, unknown
  asset rejection, profile stability, and descriptor labels URL exposure.
- [ ] 2.3 Add schema tests for v1 UUID, chronology, overlap, `strike`-only,
  80-sample range, indexes, and timestamp validation against decoded records.
- [ ] 2.4 Test malformed labels handling separately: a core package opens while
  label-aware consumers warn/ignore, and training rejects the source.

## 3. Document the contract

- [ ] 3.1 Update the package README and recording-package documentation with
  the optional file, JSON v1 example, absence semantics, and preservation rule.
- [ ] 3.2 Update IMU analyzer and CNN migration documentation to use the shared
  in-package labels hand-off and remove CSV conversion language.
