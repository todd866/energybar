# Local adaptive forecasting — model 1

Energybar now retains measured PV separately and learns interpretable household
baselines, solar correction and charger-session distributions. It uses the existing
Fronius/Evnex integrations and approved weather cache. There are no new services,
credentials, network settings or charging commands.

The chart keeps its current layout. Where trained, the existing forecast uses the
learned household hourly median and solar correction. Untrained household hours
keep the existing recent 3-hour residual fallback, or stay unavailable if that
fallback is unsupported. `--json` schema 10 exposes `forecast.learning`, component
ranges and storage errors. Session distributions and forecast error summaries are
available there; they do not add a new panel or instrument row.

## What is measured and what can be learned

* **Household excluding car:** integrate PV + signed grid supply − charger AC
  power only over common observed intervals. Interpolate between known endpoints,
  never hold a last value forward, bridge an explicit failure, bridge a gap over
  seven minutes, or accept a negative residual. PV comes from actual inverter
  observations, not the archive's ambiguously anchored energy records. Grid and
  charger histories reuse the existing statistics store.
* **Household baseline:** 28-day window, weekday/weekend × hour-of-day, median and
  observed p10/p90 across dates. Each date needs at least 45 measured minutes in a
  completed hour. Five distinct dates are required per bucket, with a qualifying
  observation in the past 14 days. Weekend hours may take three weekends to train.
  Hour windows are fixed absolute hours labelled by their local starting hour;
  a repeated DST hour counts once per date. Half-hour-offset zones consequently
  have windows starting at local :30. This is a habit baseline, not occupancy,
  appliance scheduling, holiday or temperature modelling.
* **Solar correction:** retain the uncorrected forecast alongside the corrected
  one. Once twelve previously issued daylight hours across three local dates have
  later measured outcomes (base prediction at least 200 W), use the median ratio
  of measured PV to the originally predicted base PV, bounded to 0.5–1.5. Training
  uses the last 28 days. No historical weather download or revised forecast is
  substituted for an issued prediction. Keep the prior broad weather range and
  widen it if observed ratio spread warrants; cap power at inverter capacity.
* **Charger history:** retain completed, positive-energy sessions supported by
  the existing register-validation parser. Five sessions across three dates
  enable energy and elapsed-duration p10/median/p90 plus start-hour counts.
  Elapsed duration may include pauses. These are charger-session statistics;
  the data does not identify which car was attached. They do not identify usable
  battery capacity, current SoC, the vehicle's charge limit, or active charge time.
* **Current charging requirements:** continue to use the existing explicit
  manual/estimated/telemetry provenance, freshness checks, configured capacity
  and current charge estimate. Prior-session energy never fills missing SoC or
  turns inferred full into OEM confirmation. A vintage records SoC provenance
  and whether its target and ETA were known, without storing credentials.
* **Grid balance:** solar + import = household + car + export. Bounds combine
  household low/high with solar high/low, conditional on the existing current
  car scenario. Missing car requirements remain missing. Bounds are observed
  spread/scenarios, not confidence intervals, and do not cover an unannounced
  charger restart, changed charge rate, taper or future driving.

## Prospective evaluation, not hindsight

Every five-minute background history update may save the first forecast for the
**next full absolute hour**, before that hour begins. Predictions and context are
immutable. Issuance lead varies from almost zero to one hour before the target
hour. An hour with missing components has no prediction for those components.
A later refresh cannot improve the saved prediction retroactively.

After the target hour ends plus a ten-minute source-arrival allowance, independently
score each predicted component with at least 54 minutes of measured coverage.
Actual means use covered time; partial coverage remains recorded. Freeze outcomes
once scored; missing readings do not become zero. Report signed bias (prediction
minus measurement) and mean absolute error in watts, with counts, over 28 days.
Import/export outcomes integrate both directions separately even within a
zero-crossing interval. Scores evaluate these next-hour vintages, not all-day
accuracy. The first installation has no scored forecasts.

New vintages also freeze the charger state, selected scenario, available source
timestamps and AC power, and the projected finish time when present. This context
comes from the same forecast calculation as the prediction. It never stores
account, vehicle or session identifiers. Recalculation cannot replace it.

`forecast.learning.chargeErrorsByScenario` supplements the unchanged overall
charger scores with `idle-load-observed`, `idle-no-load`, `active-charge`,
`target-reached` and `unclassified` groups (only groups with scores appear).
Charging observed after an idle forecast can reflect a start or resume; it does
not establish an erroneous completion estimate. Conversely, an active charge
expected to finish before the target hour stays in `active-charge`, even when its
predicted hourly load is zero. These remain power-error scores, not direct ETA
accuracy measurements: rate changes, pauses and later sessions can also contribute.
Existing schema-1 vintages without charger context remain readable and
`unclassified`; their context is never reconstructed from present state. The
coverage, closeout, retention and training thresholds are unchanged.

The deterministic walk-forward test trains only on earlier data, freezes a
prediction, adds later observations, then scores it. Future samples and future
scoring timestamps cannot enter an earlier model. This demonstrates mechanics on
synthetic repeating demand, not real-house accuracy. Historical data without saved
weather vintages cannot establish historical solar forecast skill.

## Storage, startup and limits

`~/.local/state/energybar/learning.json` is a private, versioned, source-bound ledger:
90 days; at most 130,000 PV records (first actual sample per minute, explicit failed
poll wins the minute), 1,000 completed sessions and 2,200 vintages; at most 16 MiB.
It uses 0600 atomic file replacement and a 0700 directory. IDs are hashed, extra
session fields discarded, and this file is gitignored. Corrupt, incompatible or
source-mismatched state is reported and preserved. No private history is in tests
or repository documents.

The existing installed meter history has no durable measured PV. Learning begins
collecting it on this version; archive PV is not relabelled as precise coincident
telemetry. Startup has no invented baseline, correction, session distribution or
accuracy score. Models are prepared on the existing serial background store queue
at most once per five minutes, expire after ten minutes, and never block popover
opening. Closed periods are required; active/partial sessions cannot train a
completed-session distribution. Learning is bounded by app uptime, sampling gaps
and the availability of the existing providers.

Validation: `Tests/test_learning.m` covers chronological cutoffs, coverage/gaps,
source and persistence safety, distribution thresholds, immutable vintages,
measured scoring and walk-forward comparisons. `Tests/test_forecast.m` checks
learned/fallback hours, solar correction, conditional grid bounds, expired models
and unknown current car data. Standard builds also run the existing native
presentation and exact-pixel chart regressions.
