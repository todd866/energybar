# Car charging estimates

Energybar 0.5.2 keeps the three instrument rows. A compact duration sits centered
above a target marker on the existing Car battery gauge. The Details view gives
the destination, approximate local finish time, AC-to-pack assumption and changing
power/taper caveat. Power now and energy today retain their columns.

The formula is `(target% − SoC%) / 100 × configured usable Wh / estimated pack W`.
Estimated pack W is **Evnex charger AC watts × EV_CHARGE_EFFICIENCY**, never PV,
whole-home power or grid export. This is a current-rate projection, including in
Solar mode. It does not predict future sunshine, household use, pauses or taper.
There is no manufacturer remaining-time or measured net pack-power feed today.
No specific taper curve is invented. A new lower charging rate extends the ETA
immediately; recent changes over 20% are identified in Details. No warm-up history
is required before showing the first defensible estimate.

`EV_CHARGE_TARGET_PERCENT` is an optional **display-only** copy of the vehicle's
actual setting. It sends no commands. If unset or invalid, the marker projects
to 100% and says **limit unknown**; this is hypothetical time to full, not a claim
about the car's cap. No 80% laptop rule is applied. No second full-charge promise
is shown when a lower target is configured.

Durations round up to 5 minutes below an hour and 0.1 hours thereafter; under
5 minutes stays `<5m`, never `0m` or prematurely complete. At or above the target,
the duration label and target marker disappear. Details retains confirmed
completion or the inferred estimate awaiting vehicle confirmation. Paused,
disconnected, fault and missing/stale data
have no numeric ETA. Details and the accessibility label give the reason.

Freshness is evaluated each time the view is presented: status ≤150 seconds,
Evnex meter ≤7 minutes (the source uploads every five minutes), direct SoC ≤30
minutes. Inferred SoC must first pass the existing cable/energy continuity rules.
Helper errors, booleans, future timestamps and old measurements with newly
updated check times cannot masquerade as a fresh battery level.

`--dump --json` schema 8 adds `chargingEstimate`, with availability, reason,
target provenance, current-rate seconds and estimated pack watts. The vehicle
object adds configured capacity, efficiency and cloud error. `--dump --render
/path/prefix` saves the actual live view model as light/dark PNGs without showing
a window. This is a one-shot diagnostic using the existing authenticated reads.
