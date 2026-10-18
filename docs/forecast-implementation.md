# Forecast chart and prepared opening

The chart uses measured PV, time-aligned site/charger history and an optional
Open-Meteo radiation response. Home demand excludes the car. The current-rate
charging estimate supplies the completion instant: integration splits there,
retains gross import and export in the final partial bar, and projects zero car
load afterward. This is a conditional scenario, not an OEM completion promise.

The 400-point popover keeps three instrument rows, its existing chart and footer.
The default Today view runs from local midnight to midnight, including the
remaining daylight and 23/25-hour daylight-saving days. The 48-hour view uses
36 past and 12 future. The interval containing Now is split exactly at the
observation time, so solid measured bars never extend into the future. Solid bars are observations; softer fills after the Now divider are
projections. A quiet future tint and separated region label preserve the distinction
without textured backgrounds. Missing values stay gaps and remain unavailable in
interval details and accessibility text. Selecting an interval gives the assumptions and source ages.
Solar, home and car have independent availability and expiry clocks. A signed-out
vehicle or missing SoC suppresses only its charging scenario and the grid balance
that depends on it. It cannot suppress calibrated solar or the measured household
baseline. A fresh paused/unplugged status supports a conditional zero car load
without battery telemetry. Unknown active charging never becomes zero.

When a complete balance is unavailable, the chart retains the future window and
draws any known solar generation as softly filled orange bars. Unknown
allocations remain gaps. Interval details show independently known home/car values; missing
car, import and export are marked unavailable. If all inputs are missing, the
future region remains empty and subtly tinted after Now instead of reverting to a history-only
chart. Today always includes the rest of the local day; 48 hours adds the longer
history and a twelve-hour outlook. No control is scheduled.

History reads, tariff integration and forecast preparation run outside the
opening action. A prepared AppKit view opens without animation. Coalescing and
revision checks reject outdated work; a bounded opening-time guard expires stale
estimates without rebuilding history on the main thread.

Forecast queries require an explicit private consent record. Coordinates are
rounded to three decimals and sent only to the selected provider; the request
contains no car or account identifier. At most one attempt per hour runs while
the app is open. The cache preserves retrieval time and expires after two hours.
Configuration, location and live captures belong outside the repository.

Unit tests cover energy conservation, exact completion splitting, near-target
behavior, startup gaps, stale/future clocks and prepared presentation under a
blocked history queue. They also cover signed-out, partial and fully unavailable
outlooks, component expiry and the observed/projected boundary in both windows.
Visual tests use synthetic values and render offscreen.
