# Energybar 0.5.0 — telemetry trust hardening

This release replaces several optimistic assumptions with explicit provenance and
partial availability.

- A solar pause is no longer interpreted as a full battery. Only a direct
  manual, live, or OBD reading can anchor an estimate.
- Unplugging writes a durable tombstone, clears older manual SoC while preserving
  readiness, and prevents stale percentages from returning after cache loss.
  Explicit clearing records a high-water mark so retained history cannot recreate
  the tombstone the user just cleared.
- Evnex attempt backoff is tracked separately from Fronius refresh targets.
  Partial Evnex status or meter results remain useful; missing meter data is
  never stored as zero.
- Charger mutations are serialized, validate transport and HTTP status, retry one
  authentication failure, invalidate connector cache, and force a fresh poll.
- History integration skips gaps over seven minutes. Charts omit unknown series,
  preserve grid/charge extrema, and treat exported power as already net of car
  load.
- Supported Fronius inverters now backfill exact archived PV-energy intervals
  into a source-bound private cache. Window summaries are lower bounds that omit
  ambiguous boundary intervals and do not claim unverified whole-site
  completeness. Evnex session history recovers exact charger-register watt-hours
  and confirmed disconnects after downtime. Neither source is expanded into a
  synthetic power curve, and residential Evnex credentials cannot recover
  historical CT/grid readings, so those chart and Grid gaps remain explicit.
- Inferred vehicle SoC uses exact session totals without double-counting sampled
  energy. An offline interval that is not spanned by trustworthy session evidence
  now makes the estimate unknown instead of assuming the car remained connected.
- Render tests use a fixed clock and explicit 2x output. Missing baselines fail;
  snapshot replacement is opt-in and happens only after semantic checks pass.
- Configuration parsing, private token/sample persistence, fixture sanitization,
  arm64-only builds, bundle metadata, signatures, and CLI smoke tests are covered
  by the release path. No Intel component is built or launched, eliminating that
  macOS compatibility warning path entirely.

The JSON dump schema is version 6. Evnex exposes status, meter, and complete
session-history availability separately; Fronius exposes its archive summary;
unavailable numeric readings are `null`; and vehicle output includes `estimated`,
`socSource`, session-energy/continuity provenance, timestamps, any unplug
invalidation tombstone, and a nullable vehicle persistence error.
