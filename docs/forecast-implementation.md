# Forecast chart and prepared opening

The chart uses measured PV, time-aligned site/charger history and an optional
Open-Meteo radiation response. Home demand excludes the car. The current-rate
charging estimate supplies the completion instant: integration splits there,
retains gross import and export in the final partial bar, and projects zero car
load afterward. This is a conditional scenario, not an OEM completion promise.

The 400-point popover keeps three instrument rows, its existing chart and footer.
The 12-hour view has eight hours of history and four projected hours; 48 hours
uses 36 past and 12 future. Solid bars are observations; outlined bars are
projections. Selecting an interval gives the assumptions and source ages.
Solar, home and car have independent availability and expiry clocks. A signed-out
vehicle or missing SoC suppresses only its charging scenario and the grid balance
that depends on it. It cannot suppress calibrated solar or the measured household
baseline. A fresh paused/unplugged status supports a conditional zero car load
without battery telemetry. Unknown active charging never becomes zero.

When a complete balance is unavailable, the chart retains the future window and
draws any known solar generation as orange outlines over the hatched unknown
allocations. Interval details show independently known home/car values; missing
car, import and export are marked unavailable. If all inputs are missing, the
future region remains hatched after Now instead of reverting to a history-only
chart. The default 12-hour window is still eight hours past and four ahead; use
48 hours for the twelve-hour outlook. No control is scheduled.

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
