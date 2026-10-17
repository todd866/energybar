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
Missing/stale inputs suppress projections. No control is scheduled.

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
blocked history queue. Visual tests use synthetic values and render offscreen.
