#!/usr/bin/env python3
"""Geely EX5 climate controller: departure pre-cool, all-day overheat protection, cool-now."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import logging
import math
import os
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Callable

LOG = logging.getLogger("geely_climate")

LEAD_MIN = 5
LEAD_MAX = 30
ALL_DAY_BURST_MIN = 10
MIN_BURST_GAP_MIN = 30
MAX_BURSTS_PER_DAY = 12
READING_FRESH_MIN = 45
READING_STALE_MIN = 60
DEPARTURE_STALE_MIN = 3 * 60
TICK_GRACE_MIN = 5
LOG_MAX = 50
TYPICAL_START_EXCESS_C = 8.0
CLIMATE_ACTIVE_FRESH_MIN = 30
FAILED_RETRY_GAP_MIN = 15
MAX_BURST_MIN = 30          # hard ceiling on any single command, whatever the caller asks

SETTINGS_PATH = os.path.expanduser("~/.config/energybar/climate.json")
STATE_PATH = os.path.expanduser("~/.cache/energybar/climate-state.json")
VEHICLE_PATH = os.path.expanduser("~/.cache/energybar/vehicle-cloud.json")
SAMPLES_PATH = os.path.expanduser("~/.cache/energybar/samples.jsonl")
LOCK_PATH = os.path.expanduser("~/.cache/energybar/climate-state.lock")
HELPER_DIR = os.path.expanduser("~/.local/state/energybar-geely")
SESSION = os.path.join(HELPER_DIR, "session", "session.json")


def default_settings() -> dict:
    return {
        "version": 1,
        "departure": {
            "enabled": False,
            "time": "07:45",
            "days": [1, 2, 3, 4, 5],
            "targetC": 24,
        },
        "allDay": {
            "enabled": False,
            "days": [],
            "onDate": None,
            "from": "09:00",
            "until": "17:00",
            "limitC": 35,
            "solarOnlyAtHome": True,
            "dailyCapKWh": 1.5,
            "minSocPct": 50,
        },
        "assumedKW": 2.0,
    }


def default_state() -> dict:
    today = dt.datetime.now().astimezone().date().isoformat()
    return {
        "version": 1,
        "updatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "todayKWh": 0.0,
        "today": today,
        "leadMinutes": 15,
        "lastBurst": None,
        "next": None,
        "blocked": None,
        "log": [],
        "lastTickMinute": None,
    }


def clamp_lead(minutes: float) -> int:
    return int(max(LEAD_MIN, min(LEAD_MAX, math.ceil(minutes))))


def parse_hhmm(value: str) -> tuple[int, int]:
    hour, minute = value.split(":", 1)
    return int(hour), int(minute)


def parse_iso(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def local_date(now: dt.datetime) -> str:
    return now.astimezone().date().isoformat()


def combine_local(now: dt.datetime, hhmm: str) -> dt.datetime:
    hour, minute = parse_hhmm(hhmm)
    local = now.astimezone()
    return local.replace(hour=hour, minute=minute, second=0, microsecond=0)


@dataclass(frozen=True)
class Decision:
    fire: bool
    reason: str
    minutes: int
    blocked: str | None


def vehicle_blocked(vehicle: dict) -> str | None:
    err = vehicle.get("error")
    if not err:
        return None
    if err == "signed out":
        return "signed out"
    return str(err)


def vehicle_reading_at(vehicle: dict) -> dt.datetime | None:
    at = vehicle.get("at")
    if not at:
        return None
    try:
        return parse_iso(at)
    except (ValueError, TypeError):
        return None


def reading_age_minutes(vehicle: dict, now: dt.datetime) -> float | None:
    measured = vehicle_reading_at(vehicle)
    if measured is None:
        return None
    if measured.tzinfo is None:
        measured = measured.replace(tzinfo=dt.timezone.utc)
    return (now - measured.astimezone(dt.timezone.utc)).total_seconds() / 60


def all_day_schedule_active(settings: dict, now: dt.datetime) -> bool:
    ad = settings["allDay"]
    if not ad.get("enabled"):
        return False
    if ad.get("onDate"):
        return ad["onDate"] == local_date(now)
    return now.astimezone().isoweekday() in (ad.get("days") or [])


def departure_schedule_active(settings: dict, now: dt.datetime) -> bool:
    dep = settings["departure"]
    if not dep.get("enabled"):
        return False
    return now.astimezone().isoweekday() in (dep.get("days") or [])


def in_time_window(now: dt.datetime, start: str, end: str) -> bool:
    start_at = combine_local(now, start)
    end_at = combine_local(now, end)
    local = now.astimezone()
    if end_at <= start_at:
        return False
    return start_at <= local < end_at


def parse_samples(samples: list[dict]) -> list[dict]:
    out: list[dict] = []
    for row in samples:
        if not isinstance(row, dict):
            continue
        parsed = dict(row)
        t = row.get("t")
        if isinstance(t, str):
            try:
                parsed["_t"] = parse_iso(t)
            except ValueError:
                continue
        elif isinstance(t, (int, float)):
            parsed["_t"] = dt.datetime.fromtimestamp(t, dt.timezone.utc)
        else:
            continue
        if "supplyW" in row and row["supplyW"] is not None:
            try:
                parsed["_supplyW"] = float(row["supplyW"])
            except (TypeError, ValueError):
                pass
        out.append(parsed)
    out.sort(key=lambda r: r["_t"])
    return out


def solar_export_watts(samples: list[dict], now: dt.datetime, max_age_min: float = 10) -> float | None:
    """Newest sample with supplyW within max_age_min; negative supplyW is export (watts)."""
    parsed = parse_samples(samples)
    if not parsed:
        return None
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    cutoff = now - dt.timedelta(minutes=max_age_min)
    best = None
    for row in reversed(parsed):
        t = row["_t"]
        if t.tzinfo is None:
            t = t.replace(tzinfo=dt.timezone.utc)
        if t < cutoff:
            break
        if "_supplyW" in row:
            best = row["_supplyW"]
            break
    return best


def solar_surplus_ok(samples: list[dict], now: dt.datetime, assumed_kw: float) -> bool:
    supply = solar_export_watts(samples, now)
    if supply is None:
        return False
    export_w = max(0.0, -supply)
    return export_w >= assumed_kw * 1000.0


def burst_energy_kwh(assumed_kw: float, minutes: int) -> float:
    return assumed_kw * minutes / 60.0


def power_block_reason(
    settings: dict,
    state: dict,
    vehicle: dict,
    minutes: int,
    now: dt.datetime,
    samples: list[dict],
    *,
    all_day: bool,
    skip_solar: bool,
) -> str | None:
    min_soc = settings["allDay"]["minSocPct"]
    soc = vehicle.get("soc")
    if soc is not None and soc < min_soc:
        return f"battery below {min_soc}%"
    if all_day:
        cap = settings["allDay"]["dailyCapKWh"]
        need = burst_energy_kwh(settings["assumedKW"], minutes)
        if state.get("todayKWh", 0) + need > cap + 1e-9:
            return "daily cap"
    if not skip_solar and settings["allDay"].get("solarOnlyAtHome"):
        # Car location is not known reliably; treat "at home" as unknown and apply the solar
        # export rule whenever solarOnlyAtHome is enabled (departure pre-cooling is exempt).
        if not solar_surplus_ok(samples, now, settings["assumedKW"]):
            return "no solar surplus"
    return None


def bursts_today_count(state: dict, today: str) -> int:
    count = 0
    for entry in state.get("log") or []:
        if entry.get("action") != "burst":
            continue
        at = entry.get("at") or ""
        if at[:10] == today:
            count += 1
    return count


def minutes_since_last_burst(state: dict, now: dt.datetime) -> float | None:
    last = state.get("lastBurst")
    if not last or not last.get("at"):
        return None
    try:
        at = parse_iso(last["at"])
    except (ValueError, TypeError):
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=dt.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    return (now - at.astimezone(dt.timezone.utc)).total_seconds() / 60


def failed_recently(state: dict, now: dt.datetime) -> bool:
    at = state.get("lastFailedAt")
    if not at:
        return False
    try:
        t = parse_iso(at)
    except (ValueError, TypeError):
        return False
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return (now - t.astimezone(dt.timezone.utc)).total_seconds() / 60 < FAILED_RETRY_GAP_MIN


def departure_fired_today(state: dict, today: str) -> bool:
    last = state.get("lastBurst")
    if not last or last.get("reason") != "departure":
        return False
    at = last.get("at") or ""
    return at[:10] == today


def learn_lead_minutes(state: dict, vehicle: dict, settings: dict, now: dt.datetime) -> int | None:
    last = state.get("lastBurst")
    if not last or not last.get("ok"):
        return None
    reading_at = vehicle_reading_at(vehicle)
    burst_at_s = last.get("at")
    if not burst_at_s or reading_at is None:
        return None
    try:
        burst_at = parse_iso(burst_at_s)
    except (ValueError, TypeError):
        return None
    if burst_at.tzinfo is None:
        burst_at = burst_at.replace(tzinfo=dt.timezone.utc)
    if reading_at.tzinfo is None:
        reading_at = reading_at.replace(tzinfo=dt.timezone.utc)
    if reading_at <= burst_at:
        return None
    start_c = last.get("startInteriorC")
    end_c = vehicle.get("interiorC")
    if start_c is None or end_c is None:
        return None
    elapsed = (reading_at - burst_at).total_seconds() / 60.0
    if elapsed < 1:
        return None
    dropped = start_c - end_c
    if dropped <= 0.05:
        return None
    rate = dropped / elapsed
    if rate <= 0:
        return None
    target = settings["departure"]["targetC"]
    excess = max(TYPICAL_START_EXCESS_C, start_c - target)
    return clamp_lead(excess / rate)


def departure_decision(
    settings: dict,
    vehicle: dict,
    state: dict,
    samples: list[dict],
    now: dt.datetime,
) -> Decision:
    if not departure_schedule_active(settings, now):
        return Decision(False, "departure", 0, None)
    today = local_date(now)
    if departure_fired_today(state, today):
        return Decision(False, "departure", 0, None)
    lead = clamp_lead(state.get("leadMinutes", 15))
    dep_at = combine_local(now, settings["departure"]["time"])
    fire_at = dep_at - dt.timedelta(minutes=lead)
    local = now.astimezone()
    if local < fire_at or local >= dep_at:
        return Decision(False, "departure", 0, None)
    age = reading_age_minutes(vehicle, now)
    target = settings["departure"]["targetC"]
    interior = vehicle.get("interiorC")
    needs_cool = (
        interior is None
        or interior > target + 1
        or (age is not None and age > DEPARTURE_STALE_MIN)
    )
    if not needs_cool:
        return Decision(False, "departure", 0, None)
    blocked = power_block_reason(
        settings, state, vehicle, lead, now, samples, all_day=False, skip_solar=True,
    )
    if blocked:
        return Decision(False, "departure", lead, blocked)
    return Decision(True, "departure", lead, None)


def all_day_decision(
    settings: dict,
    vehicle: dict,
    state: dict,
    samples: list[dict],
    now: dt.datetime,
) -> Decision:
    if not all_day_schedule_active(settings, now):
        return Decision(False, "allDay", 0, None)
    ad = settings["allDay"]
    if not in_time_window(now, ad["from"], ad["until"]):
        return Decision(False, "allDay", 0, None)
    today = local_date(now)
    if bursts_today_count(state, today) >= MAX_BURSTS_PER_DAY:
        return Decision(False, "allDay", ALL_DAY_BURST_MIN, None)
    gap = minutes_since_last_burst(state, now)
    if gap is not None and gap < MIN_BURST_GAP_MIN:
        return Decision(False, "allDay", ALL_DAY_BURST_MIN, None)
    age = reading_age_minutes(vehicle, now)
    interior = vehicle.get("interiorC")
    exterior = vehicle.get("exteriorC")
    limit = ad["limitC"]
    probe = False
    if age is not None and age <= READING_FRESH_MIN and interior is not None and interior > limit:
        pass
    elif age is not None and age > READING_STALE_MIN and exterior is not None and exterior >= limit - 5:
        probe = True
    else:
        return Decision(False, "allDay", ALL_DAY_BURST_MIN, None)
    blocked = power_block_reason(
        settings,
        state,
        vehicle,
        ALL_DAY_BURST_MIN,
        now,
        samples,
        all_day=True,
        skip_solar=False,
    )
    if blocked:
        return Decision(False, "allDay", ALL_DAY_BURST_MIN, blocked)
    if probe:
        return Decision(True, "allDay", ALL_DAY_BURST_MIN, None)
    return Decision(True, "allDay", ALL_DAY_BURST_MIN, None)


def cool_now_decision(
    settings: dict,
    vehicle: dict,
    state: dict,
    samples: list[dict],
    now: dt.datetime,
    minutes: int,
) -> Decision:
    blocked = power_block_reason(
        settings, state, vehicle, minutes, now, samples, all_day=False, skip_solar=True,
    )
    if blocked:
        return Decision(False, "coolNow", minutes, blocked)
    return Decision(True, "coolNow", minutes, None)


def decide(
    settings: dict,
    vehicle: dict,
    state: dict,
    samples: list[dict],
    now: dt.datetime,
    *,
    cool_now_minutes: int | None = None,
) -> Decision:
    blocked = vehicle_blocked(vehicle)
    if blocked:
        return Decision(False, "", 0, blocked)
    age = reading_age_minutes(vehicle, now)
    if vehicle.get("climateActive") and age is not None and age <= CLIMATE_ACTIVE_FRESH_MIN:
        return Decision(False, "", 0, None)
    if failed_recently(state, now):
        return Decision(False, "", 0, "retrying after a failed command")
    if cool_now_minutes is not None:
        return cool_now_decision(settings, vehicle, state, samples, now, cool_now_minutes)
    dep = departure_decision(settings, vehicle, state, samples, now)
    if dep.fire or dep.blocked:
        return dep
    return all_day_decision(settings, vehicle, state, samples, now)


def normalize_state(state: dict, now: dt.datetime) -> dict:
    out = {**default_state(), **state}
    today = local_date(now)
    if out.get("today") != today:
        out["today"] = today
        out["todayKWh"] = 0.0
    out["leadMinutes"] = clamp_lead(out.get("leadMinutes", 15))
    return out


def compute_next_departure(settings: dict, state: dict, now: dt.datetime) -> dict | None:
    if not settings["departure"].get("enabled"):
        return None
    dep_time = settings["departure"]["time"]
    lead = clamp_lead(state.get("leadMinutes", 15))
    local = now.astimezone()
    for offset in range(0, 8):
        day = local.date() + dt.timedelta(days=offset)
        probe = local.replace(year=day.year, month=day.month, day=day.day)
        if not departure_schedule_active(settings, probe):
            continue
        dep_at = combine_local(probe, dep_time)
        fire_at = dep_at - dt.timedelta(minutes=lead)
        if offset == 0 and fire_at <= local and not departure_fired_today(state, day.isoformat()):
            continue
        if fire_at > local:
            return {"at": fire_at.isoformat(timespec="seconds"), "reason": "departure"}
    return None


def append_log(state: dict, now: dt.datetime, action: str, reason: str) -> None:
    log = list(state.get("log") or [])
    log.append({"at": now.astimezone().isoformat(timespec="seconds"), "action": action, "reason": reason})
    state["log"] = log[-LOG_MAX:]


def apply_tick_state(
    state: dict,
    decision: Decision,
    settings: dict,
    vehicle: dict,
    now: dt.datetime,
    *,
    fired: bool,
    ok: bool,
) -> dict:
    state = normalize_state(state, now)
    learned = learn_lead_minutes(state, vehicle, settings, now)
    if learned is not None:
        state["leadMinutes"] = learned
    state["updatedAt"] = now.astimezone().isoformat(timespec="seconds")
    state["lastTickMinute"] = now.astimezone().strftime("%Y-%m-%dT%H:%M")
    state["next"] = compute_next_departure(settings, state, now)
    if decision.blocked and not decision.fire:
        state["blocked"] = decision.blocked
    elif vehicle_blocked(vehicle):
        state["blocked"] = vehicle_blocked(vehicle)
    elif decision.fire and decision.blocked:
        state["blocked"] = decision.blocked
    else:
        state["blocked"] = decision.blocked if decision.blocked else None
    if decision.fire and not fired:
        state["lastFailedAt"] = now.astimezone().isoformat(timespec="seconds")
        append_log(state, now, "error", "command failed")
    elif decision.fire and fired:
        kwh = burst_energy_kwh(settings["assumedKW"], decision.minutes)
        state["todayKWh"] = state.get("todayKWh", 0) + kwh
        burst = {
            "at": now.astimezone().isoformat(timespec="seconds"),
            "reason": decision.reason,
            "minutes": decision.minutes,
            "ok": ok,
            "startInteriorC": vehicle.get("interiorC"),
        }
        state["lastBurst"] = burst
        note = "probe" if (
            decision.reason == "allDay"
            and reading_age_minutes(vehicle, now) is not None
            and reading_age_minutes(vehicle, now) > READING_STALE_MIN
        ) else decision.reason
        append_log(state, now, "burst" if ok else "error", note if ok else "fire failed")
        state["blocked"] = None
    elif not decision.fire:
        if decision.blocked:
            append_log(state, now, "skip", decision.blocked)
        elif decision.reason:
            append_log(state, now, "skip", "conditions not met")
    return state


def target_temp_c(settings: dict, reason: str) -> int:
    if reason == "departure":
        return int(round(settings["departure"]["targetC"]))
    if reason == "coolNow":
        return int(round(settings["departure"]["targetC"]))
    return 22


def duration_seconds(minutes: int) -> str:
    """rapid_climate's duration is seconds (the library's AC default "180" is 3 min)."""
    return str(int(max(1, min(MAX_BURST_MIN, minutes)) * 60))


def _write_private(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def load_json(path: str, default: Callable[[], dict]) -> dict:
    try:
        with open(path) as handle:
            data = json.load(handle)
        if isinstance(data, dict):
            base = default()
            base.update(data)
            return base
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    return default()


def load_samples(path: str) -> list[dict]:
    rows: list[dict] = []
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except OSError:
        pass
    return rows


class FileLock:
    def __init__(self, path: str):
        self.path = path
        self._fd: int | None = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self._fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(self._fd)
            self._fd = None
            raise exc
        return self

    def __exit__(self, *exc):
        if self._fd is not None:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
            os.close(self._fd)
            self._fd = None


def build_client():
    sys.path.insert(0, os.path.join(HELPER_DIR, "vendor"))
    from geely import api as geely  # noqa: E402
    from geely.const import CLIENT_ID, region_config  # noqa: E402

    with open(SESSION) as handle:
        session = json.load(handle)
    backend = region_config(session["region"])
    return geely.GeelyApi(
        app_id=backend["app_id"],
        app_secret=backend["app_secret"],
        user_id=session["user_id"],
        vin=session["vin"],
        cidpsso_token=session["token"],
        client_id=CLIENT_ID,
        vehicle_series=session["model"],
        vehicle_model=session["model"],
        device_id=session["device_id"],
        cert_path=session["cert"],
        key_path=session["key"],
        control_host=backend["control_host"],
        email=session.get("email"),
    )


Firer = Callable[[Decision, dict], bool]


def default_firer(decision: Decision, settings: dict) -> bool:
    client = build_client()
    temp = str(target_temp_c(settings, decision.reason))
    duration = duration_seconds(decision.minutes)
    client.rapid_climate(
        ac=True,
        temp=temp,
        heat_seats=None,
        vent_seats=None,
        vlt=False,
        duration=duration,
    )
    return True


def fire_decision(
    decision: Decision,
    settings: dict,
    firer: Firer | None,
    *,
    dry_run: bool,
) -> bool:
    if dry_run or firer is None:
        LOG.info("dry-run: would fire %s for %s min", decision.reason, decision.minutes)
        return True
    try:
        return firer(decision, settings)
    except Exception as exc:
        LOG.exception("rapid_climate failed: %s", exc)
        return False


def tick_once(
    *,
    now: dt.datetime | None = None,
    dry_run: bool = False,
    firer: Firer | None = default_firer,
    settings_path: str = SETTINGS_PATH,
    state_path: str = STATE_PATH,
    vehicle_path: str = VEHICLE_PATH,
    samples_path: str = SAMPLES_PATH,
    lock_path: str = LOCK_PATH,
) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    settings = load_json(settings_path, default_settings)
    state = load_json(state_path, default_state)
    vehicle = load_json(vehicle_path, lambda: {})
    samples = load_samples(samples_path)
    state = normalize_state(state, now)
    tick_key = now.astimezone().strftime("%Y-%m-%dT%H:%M")
    if state.get("lastTickMinute") == tick_key:
        _write_private(state_path, state)
        return 0
    try:
        with FileLock(lock_path):
            decision = decide(settings, vehicle, state, samples, now)
            fired = False
            ok = False
            if decision.fire and not decision.blocked:
                ok = fire_decision(decision, settings, firer, dry_run=dry_run)
                fired = ok or dry_run
            state = apply_tick_state(state, decision, settings, vehicle, now, fired=fired, ok=ok)
            if dry_run:
                print(json.dumps({"decision": decision.__dict__, "state": state}, indent=1))
                return 0
            _write_private(state_path, state)
            if decision.fire and not ok and not dry_run:
                return 1
    except BlockingIOError:
        LOG.warning("tick skipped: lock held")
    return 0


def cool_now(
    minutes: int,
    *,
    dry_run: bool = False,
    firer: Firer | None = default_firer,
    settings_path: str = SETTINGS_PATH,
    state_path: str = STATE_PATH,
    vehicle_path: str = VEHICLE_PATH,
    samples_path: str = SAMPLES_PATH,
    lock_path: str = LOCK_PATH,
) -> int:
    now = dt.datetime.now(dt.timezone.utc)
    settings = load_json(settings_path, default_settings)
    state = load_json(state_path, default_state)
    vehicle = load_json(vehicle_path, lambda: {})
    samples = load_samples(samples_path)
    state = normalize_state(state, now)
    blocked = vehicle_blocked(vehicle)
    if blocked:
        print(blocked, file=sys.stderr)
        return 2
    if vehicle.get("climateActive"):
        print("climate already active", file=sys.stderr)
        return 3
    decision = decide(settings, vehicle, state, samples, now, cool_now_minutes=minutes)
    if decision.blocked:
        print(decision.blocked, file=sys.stderr)
        state["blocked"] = decision.blocked
        _write_private(state_path, state)
        return 4
    if not decision.fire:
        print("cannot cool now", file=sys.stderr)
        return 5
    try:
        with FileLock(lock_path):
            ok = fire_decision(decision, settings, firer, dry_run=dry_run)
            state = apply_tick_state(state, decision, settings, vehicle, now, fired=ok or dry_run, ok=ok)
            if dry_run:
                print(json.dumps({"decision": decision.__dict__}, indent=1))
                return 0
            _write_private(state_path, state)
    except BlockingIOError:
        print("controller busy", file=sys.stderr)
        return 6
    if not ok and not dry_run:
        print("fire failed", file=sys.stderr)
        return 7
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(prog="geely_climate")
    parser.add_argument("command", choices=["tick", "cool-now", "status"])
    parser.add_argument("--minutes", type=int, default=10)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "tick":
        return tick_once(dry_run=args.dry_run, firer=None if args.dry_run else default_firer)
    if args.command == "cool-now":
        return cool_now(args.minutes, dry_run=args.dry_run, firer=None if args.dry_run else default_firer)
    try:
        with open(STATE_PATH) as handle:
            json.dump(json.load(handle), sys.stdout, indent=1)
        print()
    except OSError as exc:
        print(f"cannot read state: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())