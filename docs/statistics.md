# Recorded statistics

**⋯ → Statistics…** opens a prepared four-row view. Day/Week and previous/next
controls browse recorded solar, gross grid import, gross grid export and car
energy. The three live instrument rows and forecast chart are unchanged.

The date range, observation cutoff and independent coverage remain visible.
`~` identifies integration of measured power, which approximates energy between
readings. `≥` identifies the conservative sum of whole solar-register intervals.
Unavailable values use a dash; measured zero remains zero. Coverage rounds known
hours down and elapsed hours up so a short missing interval cannot look complete.
Details gives source measurement clocks and limitations. There are no projected
values in this view.

## Persistence and bounds

`~/.local/state/energybar/statistics.json` is local only. Its directory is 0700;
the file is 0600, written through an atomic rename with file/directory fsync.
The schema contains a source fingerprint, timestamps, measured meter watts and
whole archived solar-energy records. Device identifiers are hashed. It contains
no account credentials, location, vehicle identity, SoC or forecast payload.

History retains 90 × 24 hours, at most 50,000 rows per series and at most 16 MiB.
The view offers 90 local calendar dates, with partial coverage at a retention
boundary. Older rows are pruned during the next successful merge. Calendar days
and Monday weeks follow the configured tariff timezone, otherwise the Mac's
timezone, and honor daylight-saving boundaries.

Merges run on the existing serial history queue at most once per five minutes,
using the existing meter and PV archive caches. No provider polling, credentials
or permissions are added. Duplicate source timestamps replace the same record;
overlapping caches never accumulate duplicate energy. A corrupt, unreadable or
source-mismatched file is preserved and the statistics error is shown. A changed
source cannot inherit the earlier source's totals. The main readout still runs.

## Coverage and provenance

Grid and car use their independent measured-power endpoints. Status-only
checkpoints do not become power readings. A missing endpoint or gap longer than
seven minutes breaks that series; a final reading is never extended to now.
Intervals crossing local midnight are clipped with linear endpoint interpolation.
Zero-crossings retain both gross import and gross export instead of netting them.

Solar uses the inverter's energy register, not integration of forecast or chart
bars. Because the API's interval anchor direction is not established, a record is
included only when both possible start/end interpretations fit inside one day.
Distinct source records are summed once by device and anchor, matching the existing
archive reader. Small differences between anchor spacing and recorder duration do
not discard energy. Coverage unions recorded time under both possible anchor
directions and takes the smaller result, then averages across observed inverter
devices; it does not establish complete site coverage. Weekly totals sum
the same conservative daily records, including their boundary omissions.

The first merge can recover only the existing roughly 48-hour caches. Days before
collection are empty, and time while the app was stopped remains missing unless
the existing solar archive recovers it. Charger-session registers are not added
on top of power-derived car energy, avoiding double counting and ambiguous day
allocation. Historical prices are not inferred from the current tariff; existing
Today electricity cost presentation remains available separately.

Unplugged household-meter freshness and a sustainable on-demand read quota remain
unverified. This feature makes no new meter requests and does not fill those gaps.

## Focused validation

Run `zsh tools/test-statistics.sh` for the bounded statistics suite, app-controller
syntax check, and eight native offscreen views in `build/statistics-render/`.
Checks cover midnight/DST, gross directions, gaps, independent series, correction
deduplication, archive overlap/boundaries, count/time bounds, source mismatch,
corrupt-file preservation, private file modes, restart, empty startup and prepared
navigation. Full builds also run the statistics tests and optional sanitizers.
