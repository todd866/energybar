"""Pure conversion of Geely's last uploaded snapshot; never performs I/O."""
from __future__ import annotations

import datetime as dt
import math


def _walk(value, *keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def _number(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return None
    try:
        number = float(value)
        return number if math.isfinite(number) else None
    except (ValueError, OverflowError):
        return None


def snapshot_cache(response, *, checked_at: str) -> dict:
    """Keep measurement time separate from check time, including on bad payloads.

    Geely updateTime is epoch milliseconds. Unknown units, missing/malformed
    times and clocks over 60 seconds ahead cannot produce a usable SOC anchor.
    Old but valid measurement times remain old; the consumer applies its TTL.
    """
    out = {"checkedAt": checked_at, "source": "geely cloud"}
    status = _walk(response, "data")
    if not isinstance(status, dict):
        status = response
    ev = _walk(status, "vehicleStatus", "additionalVehicleStatus", "electricVehicleStatus")
    soc = _number(_walk(ev, "chargeLevel"))
    if soc is None or not 0 <= soc <= 100:
        out["error"] = "no valid battery level in status"
        return out
    updated = _walk(status, "vehicleStatus", "updateTime")
    if updated is None:
        updated = _walk(status, "updateTime")
    milliseconds = _number(updated)
    try:
        checked = dt.datetime.fromisoformat(checked_at.replace("Z", "+00:00"))
        if checked.tzinfo is None or milliseconds is None:
            raise ValueError("missing measurement time")
        # Reject seconds, booleans and implausible pre-2010 dates, rather than
        # guessing another unit or substituting the poll clock.
        if milliseconds < 1262304000000 or milliseconds > (checked.timestamp() + 60) * 1000:
            raise ValueError("invalid measurement time")
        measured = dt.datetime.fromtimestamp(milliseconds / 1000, dt.timezone.utc)
    except (ValueError, OverflowError, OSError):
        out["error"] = "measurement time unavailable"
        return out
    out.update(soc=soc, at=measured.isoformat())
    distance = _number(_walk(ev, "distanceToEmptyOnBatteryOnly"))
    if distance is not None and distance >= 0:
        out["rangeKm"] = distance
    return out
