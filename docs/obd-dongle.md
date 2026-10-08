# OBD dongle → vehicle SoC (deferred)

**Date:** 7 August 2026  
**Vehicle:** User-configured plug-in vehicle
**Status:** Research and Energybar seam only. No BLE poller or PID values yet.

`TODO(obd):` markers in `Sources/vehicle.{h,m}` and `Sources/main.m` are the
searchable backlog for this work.

## Why this path

| Path | Verdict |
|------|---------|
| Supported manufacturer API | None confirmed for the installed vehicle |
| Home Wi-Fi | Infotainment and updates only; no known LAN SoC endpoint |
| Mobile-app traffic capture | Possible research; pinning and signing unknown |
| **OBD-II dongle** | **Preferred direct-percentage path** — local, account-free, and in range while charging at home |

Inferred and manual SoC remain the shipped fallback until this lands.

## Battery capacity

Set `EV_BATTERY_KWH` from the vehicle's own specification. Energybar deliberately
does not hard-code a make, model, chemistry, or pack size.

## Hardware guidance

Use an adapter with a genuine sleep or battery-saver mode. Cheap always-awake
ELM327 clones can flatten the 12 V battery or keep the vehicle bus awake.

Before buying for unattended use, confirm that the adapter:

- supports the host platform and intended OBD application;
- sleeps reliably when the vehicle is idle;
- can expose the manufacturer-specific SoC signal; and
- can be removed easily if it causes bus or battery issues.

## Validate before implementing

Use an established OBD application and the correct profile for the vehicle.

1. Connect with a sleep-capable adapter.
2. Select the exact vehicle profile if one exists.
3. Confirm battery SoC tracks the dashboard or official app.
4. Record whether the application exposes display SoC, BMS SoC, or both.
5. Only then capture the request and response needed by Energybar.

If the application cannot show a trustworthy SoC value, stop. Do not invent PIDs.

## PID discovery sequence

Once an existing application proves the signal exists:

1. Capture the request and response for that sensor using a supported export,
   BLE trace, or ELM command log.
2. Record the CAN identifier, mode and PID bytes, response length, scale and
   offset, and units.
3. Put the PID and scale in configuration; define the final `OBD_PID` format only
   when the first verified value exists.
4. Implement a small sidecar that polls over BLE and writes the cache below.
5. Enable `EBVehicleOBDProvider`; a fresh direct reading removes the `est.` label.

## Energybar interface

Resolution order:

```
OBD → live API → inferred → manual → stub
```

The sidecar writes `~/.cache/energybar/obd.json` with mode `0600`:

```json
{
  "soc": 58.0,
  "at": "2026-08-07T12:00:00.000Z",
  "pid": "<verified opaque identifier>",
  "adapter": "<adapter identifier>"
}
```

`EBVehicleOBDProvider` may report available only when `soc` is valid and `at` is
newer than `OBD_MAX_AGE_SECONDS`. Missing or stale input remains unknown.

## Poll etiquette

- Poll only while Evnex reports the car plugged in.
- Do not poll overnight while parked and idle.
- Prefer no more than one status read every several minutes while charging.
- Stop on unplug or repeated failures.

Waking ECUs or holding the bus awake can drain the 12 V battery.

## Configuration seams

```sh
# OBD_CACHE_PATH=          # default ~/.cache/energybar/obd.json
# OBD_MAX_AGE_SECONDS=900  # stale → provider unavailable
# OBD_PID=                 # manufacturer request once verified
```

`EBVehicleOBDProvider` currently remains unavailable until cache parsing and
freshness checks are implemented. See `docs/vehicle-connectivity.md` for the
related cloud-interface constraints.
