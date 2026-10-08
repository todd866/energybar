# Energybar 0.5.1 — Evnex quota fix

- Grid and car power now come from the regular charge-point detail document,
  which carries the same watt readings plus their source timestamp. Energybar
  no longer polls the meter-command endpoint whose long-window quota can be
  exhausted by a 30-second cadence.
- Detail meter values are accepted only when `meter.updatedDate` is fresh.
  Unrelated document and connector timestamps cannot make an old reading look
  current.
- A positive car-power value retained by the charger is forced to zero unless
  that connector is currently OCPP `CHARGING`; signed grid power remains usable.
- Detail and session endpoints retain their own due times and are no longer
  gated by the removed meter-command request, so that exhausted quota cannot
  suppress otherwise healthy telemetry or shutdown recovery.
- Charger status remains a 30-second safety signal; power detail follows its
  roughly five-minute source cadence and is stored at `meter.updatedDate`.
  The next detail fetch phase-aligns to that source clock, so a late-cycle
  reading is refreshed before it crosses the seven-minute freshness limit.
  Status-only checks do not create false meter samples, while a failed due
  detail request records an explicit history gap.
- Detail failures remain visibly stale until a later successful detail fetch.
  Fresh status immediately zeros retained connector power after a definite
  unplug, wait, or fault state. Source-time samples are sorted and deduplicated
  before integration; current PV and status are never misdated onto them.
- Five-minute charger-status checkpoints are persisted as explicitly
  `statusOnly` rows. They survive relaunch for vehicle continuity and unplug
  safety while remaining excluded from every power/energy adjacency.
