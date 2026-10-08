# Energybar

Energybar is a small native macOS menu-bar app for one home-energy question: is
solar reaching the car, being exported, or being replaced with grid power?
It combines a Fronius inverter, an Evnex charger, and optional user-supplied
vehicle state without treating missing data as zero or an estimate as fact.

## What it shows

- live PV (orange; the bar is full at the inverter's capacity, `INVERTER_KW` in `.env`), grid flow (a plain bar; the row's name and colour give the direction), and car charging power. With a known state of charge the Car bar is the pack level with a trend arrow to where it will be in an hour, as on Glancebar's battery. The grid row names the live direction: Import (red) or Export (green). With a tariff configured, its daily energy is paired with estimated cost or credit, such as `6.1 kWh · $1.83`. Hover for both directions and the live hourly cost; **⋯ → Electricity** has the rates. Tooltips are one line of figures, never a paragraph. The aligned value column fits two-digit kW readings;
- 12-hour and 48-hour history. Solar is above the marked zero, split into car (blue), home (grey) and export (green); grid import is below, in red. Rounded axis limits share one linear scale. A hatched band is a gap in the samples, not a zero. Hover gives the power breakdown and import total, with calendar dates in the 48-hour view;
- Solar and Charge now as one mode control (orange for solar, green for charge now). Stop is a separate button and asks before sending a remote stop;
- day totals with explicit partial-coverage caveats and metered shutdown recovery;
- direct or estimated vehicle SoC with visible provenance. A direct reading can come from a local helper that writes `~/.cache/energybar/vehicle-cloud.json` (`soc`, `at`, `checkedAt`, optional `rangeKm`, `source`, `error`); it is used only while the helper checked within the last 30 minutes, and an `error` is shown rather than a number;
- charger actions whose HTTP failures are shown instead of silently ignored.

The menu-bar item is icon-only by default. Error and unknown states use distinct
symbols as well as colour.

## Electricity costs

Rates are never guessed. Put the confirmed plan in
`~/.config/energybar/tariff.json`, or select another file with
`ENERGYBAR_TARIFF_PATH`. The app reloads it when the popover updates. A missing,
invalid or out-of-date tariff leaves costs unavailable; a configured zero rate
is a valid free rate.

The following is an **illustrative schedule, not a retailer's published rates**:

```json
{
  "name": "Example only",
  "currency": "AUD",
  "timeZone": "Australia/Perth",
  "bands": [
    {"startMinute": 0, "endMinute": 900, "importCents": 30, "exportCents": 2},
    {"startMinute": 900, "endMinute": 1260, "importCents": 30, "exportCents": 10},
    {"startMinute": 1260, "endMinute": 1440, "importCents": 30, "exportCents": 2}
  ]
}
```

Times are minutes after midnight in the tariff's timezone. Each day must be
covered once, without gaps or overlapping bands. Optional `weekdays` uses
1=Sunday through 7=Saturday; omit it for every day. Optional `validFrom` and
exclusive `validUntil` use `YYYY-MM-DD`. `sourceURL` records where the rates were
verified. Use the bill's tax-inclusive unit rates, in cents per kWh.

Costs are estimates from recorded grid readings, with import charges and export
credits kept separate. Intervals crossing zero retain both directions; intervals
crossing tariff boundaries use each applicable rate. Missing readings stay
unpriced and incomplete energy totals carry `≥`. **Now** identifies live power in
kW; **Today** identifies accumulated energy in kWh or net cost. A quiet divider
separates those columns. The three instrument rows stay aligned at 30pt each.
The Grid row's bar is always the live flow (green exporting, red importing); the day's money is one signed figure in the Today column (`−$1.04` is a net cost, `+$0.40` a net credit). Gross import cost and export credit, the live hourly cost and "partial" (incomplete history: recorded readings only, not a lower bound on the bill) are on hover and in **⋯ → Electricity**. Fixed daily supply charges, demand charges, rebates and solar self-consumption savings are excluded. This is not a full bill forecast. The optional menu-bar number includes its `kWh` unit.

The footer controls the car charger. **Solar only** clears the Charge now override
and returns to the charger's configured solar mode; it may wait for surplus and
does not start a session itself. **Charge now** enables the full-rate override.
**Stop** requests that the current charging session stop.

## Requirements and setup

Energybar requires macOS 13 or newer. Copy `.env.example` to
`~/.config/energybar/.env`, fill in the Fronius and Evnex identifiers, and secure
the file:

```sh
mkdir -p ~/.config/energybar
cp .env.example ~/.config/energybar/.env
chmod 600 ~/.config/energybar/.env
uvx evnex==0.7.0 auth login
```

The Evnex login command creates `~/.cache/evnex/tokens.json`. Energybar refreshes
the access token and keeps the cache private. It does not use account credentials
from its `.env`; do not store the Evnex password there.

## Build and run

```sh
ENERGYBAR_ADHOC=1 ./build.sh
pkill -x Energybar 2>/dev/null || true
mv /Applications/Energybar.app "/Applications/Energybar.app.backup-$(date +%Y%m%d-%H%M%S)"
ditto build/Energybar.app /Applications/Energybar.app
open /Applications/Energybar.app
```

`build.sh` runs unit and visual tests, builds an Apple-silicon-only app, and
verifies its version, arm64 architecture, signature, and native CLI entry
points. No Intel component is built or launched. The build uses a Developer ID
when one is installed. For a local-only build without one, explicitly set
`ENERGYBAR_ADHOC=1`; ad-hoc identity can cause macOS local-network permission to
be requested again after upgrades.

Useful diagnostics:

```sh
build/Energybar.app/Contents/MacOS/Energybar --dump
build/Energybar.app/Contents/MacOS/Energybar --dump --json
build/Energybar.app/Contents/MacOS/Energybar --version
```

`--dump` is a one-shot live diagnostic, not a polling interface. Each invocation
performs fresh network reads and does not append those readings to GUI history.

Live fixture capture writes only a sanitized preview under `build/` by default.
Replacing tracked fixtures requires both `--refresh-fixtures` and
`--accept-fixtures`.

## Trust model

- Missing or malformed telemetry stays unavailable; it is never serialized or
  integrated as a believable zero.
- Evnex status is sampled every 30 seconds while the popover is open and every two
  minutes while it is closed (each check is relayed to the charger; a timed-out
  check is retried once), while its timestamped detail meter
  is sampled at the source's roughly five-minute cadence. This avoids the much
  smaller quota on the meter-command endpoint. Status failures back off to five
  minutes; Fronius keeps its own five-second timer target between attempts.
- Grid readings may remain visible as stale, with age, but are never written back
  as fresh samples.
- Vehicle SoC is estimated only from a direct manual/live/OBD anchor plus measured
  charging energy. A pause in charging is not evidence of 100%. Any unplug event
  invalidates the percentage durably until a newer anchor is supplied; readiness
  remains independent. Timestamped charger-status checkpoints survive relaunch
  for connection continuity but are excluded from all power calculations.
- On startup and every 30 minutes, supported Fronius hardware supplies exact
  archived PV-energy intervals. Window totals are conservative lower bounds:
  ambiguous boundary intervals are omitted and whole-site completeness is not
  assumed. Evnex supplies exact charger-session
  watt-hours and confirmed disconnect times every five minutes. Both caches are
  private and source-bound, so changing inverter or charge point cannot inherit
  another device's totals.
- Recovery does not invent a missing power curve. The residential Evnex login
  exposes session energy, but not historical CT/grid meter values; Grid totals and
  the surplus-versus-car chart therefore retain honest gaps while the app was
  closed. A vehicle telemetry gap that neither live samples nor a session spans
  makes inferred SoC unknown until a newer direct anchor.
- Charge, solar, and stop commands are serialized, controls are disabled in
  flight, 401 responses refresh authentication once, and non-2xx responses are
  surfaced.

## Development

```sh
./tests.sh
ENERGYBAR_SANITIZERS=1 ./tests.sh
./tests.sh --accept-snapshots
```

Snapshot acceptance happens only after semantic visual assertions pass. Exact
pixel diffs are a same-macOS local gate; CI runs cross-version semantic/layout
visual checks, sanitizer suites, arm64 architecture checks, and a native bundle
smoke test.

The JSON dump schema is version 7. `gridCosts` exposes separate priced import
and export energy, cost and credit, currency, coverage, active rates and live
hourly amounts; unavailable costs are null. Fronius output names recovered window energy
as a lower bound and exposes interval/device coverage; Evnex output distinguishes
current, complete, exact-register session history from stale or partial data.
Vehicle output includes provenance, continuity state, timestamps, any unplug
invalidation tombstone, and a nullable `persistenceError` when safety state is
not durable.
