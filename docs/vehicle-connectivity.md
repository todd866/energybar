# Vehicle connectivity — API spike

**Date:** 7 August 2026
**Vehicle:** Plug-in vehicle with an Australian connected-services account

## Finding

No supported public developer API has been confirmed for the installed vehicle's
Australian connected service. Status, state of charge (SoC), and remote commands
are available through the manufacturer's mobile app, backed by proprietary cloud
endpoints and a dealer-linked account.

Home Wi-Fi is not a useful telemetry source: it serves infotainment and updates,
while connected services use the vehicle's embedded cellular modem. There is no
known LAN SoC endpoint comparable to the Fronius API.

## What Energybar needs

The control loop benefits from two independent vehicle fields:

1. **SoC %** — avoid pushing surplus into an already-full battery.
2. **Ready to accept charge** — distinguish plugged and ready from unplugged or
   charge-complete states.

## Current path (v0.4.0+)

| Option | Status |
|--------|--------|
| Supported manufacturer API | Not currently available |
| Home Wi-Fi | No known local telemetry |
| Scripts for other markets | Not assumed safe or compatible |
| Mobile-app traffic capture | Optional research; signing and pinning unknown |
| **OBD-II dongle** | **Preferred real SoC path**; see `docs/obd-dongle.md` |
| **Inferred SoC** | **Shipped** — manual anchor plus metered charge integration, labelled `est.` |
| **Manual SoC + ready** | **Shipped** — ⚙ → Vehicle → Set battery % / Ready to accept charge |

Resolution order: **OBD → live API → inferred → manual → stub**.

Until a live feed exists, Energybar must not invent SoC. It accepts direct OBD or
API readings, user-entered anchors, and explicitly labelled estimates derived
from metered charging.

### Preferred hardware path — OBD

First use an OBD application with the correct profile for the vehicle to confirm
that battery SoC is available. Only then capture the PID and implement a sidecar.
The hardware, discovery, 12 V safety rules, and file-drop interface are described
in `docs/obd-dongle.md`.

`EBVehicleOBDProvider` remains a seam until a sidecar writes a fresh `obd.json`
cache.

### Live API capture — blocking unknown

Traffic capture has not happened. The main unknown is whether a vehicle-status
request carries a signature over the body, timestamp, and nonce. A signed or
pinned protocol may make a stable third-party client impractical, so no endpoints
are guessed in the application.

`EBVehicleLiveProvider` remains a seam. Its private token cache is
`~/.cache/energybar/vehicle-token.json` with mode `0600` and fields
`access_token`, `refresh_token`, `expires_at`, and `vin`.

### Poll etiquette for future live sources

- Poll only while the charger reports the car plugged in.
- Avoid idle or overnight polling.
- Use a cadence no faster than 15 minutes; back off on failures.
- Stop after repeated failures until the next plug-in event.

Cloud and OBD reads can wake vehicle electronics. Conservative polling protects
the 12 V battery.
