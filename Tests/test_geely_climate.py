import datetime as dt
import tempfile
import unittest
from zoneinfo import ZoneInfo

from tools.geely_climate import (
    Decision,
    all_day_decision,
    clamp_lead,
    cool_now_decision,
    decide,
    default_settings,
    default_state,
    departure_decision,
    duration_seconds,
    learn_lead_minutes,
    normalize_state,
    solar_surplus_ok,
    tick_once,
    cool_now,
)

PERTH = ZoneInfo("Australia/Perth")


def at(hour: int, minute: int = 0, day: int = 16, month: int = 11, year: int = 2026) -> dt.datetime:
    """2026-11-16 is a Monday (ISO weekday 1) in Australia/Perth."""
    return dt.datetime(year, month, day, hour, minute, tzinfo=PERTH).astimezone(dt.timezone.utc)


def vehicle(**kw) -> dict:
    base = {"soc": 80, "at": at(7, 0).isoformat()}
    base.update(kw)
    return base


class GeelyClimateTests(unittest.TestCase):
    def settings(self, **changes) -> dict:
        s = default_settings()
        for key, value in changes.items():
            if isinstance(value, dict) and key in s and isinstance(s[key], dict):
                s[key].update(value)
            else:
                s[key] = value
        return s

    def test_departure_timing_and_once_per_day(self):
        settings = self.settings(
            departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24},
        )
        state = default_state()
        state["leadMinutes"] = 15
        now = at(7, 45)
        v = vehicle(interiorC=35)
        d = departure_decision(settings, v, state, [], now)
        self.assertTrue(d.fire)
        self.assertEqual(d.minutes, 15)
        state["lastBurst"] = {
            "at": now.astimezone().isoformat(timespec="seconds"),
            "reason": "departure",
            "minutes": 15,
            "ok": True,
        }
        d2 = departure_decision(settings, v, state, [], now)
        self.assertFalse(d2.fire)
        early = at(7, 40)
        self.assertFalse(departure_decision(settings, v, state, [], early).fire)

    def test_departure_stale_reading(self):
        settings = self.settings(departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24})
        old = at(3, 0).isoformat()
        d = departure_decision(settings, vehicle(at=old, interiorC=23), default_state(), [], at(7, 45))
        self.assertTrue(d.fire)

    def test_departure_skips_when_cool_enough(self):
        settings = self.settings(departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24})
        fresh = at(7, 30).isoformat()
        d = departure_decision(settings, vehicle(at=fresh, interiorC=24.5), default_state(), [], at(7, 45))
        self.assertFalse(d.fire)

    def test_lead_learning_clamp(self):
        settings = self.settings(departure={"targetC": 24})
        burst = at(6, 0).isoformat()
        reading = at(6, 20).isoformat()
        state = {
            "lastBurst": {
                "at": burst,
                "reason": "departure",
                "minutes": 20,
                "ok": True,
                "startInteriorC": 40,
            },
            "leadMinutes": 15,
        }
        v = vehicle(at=reading, interiorC=36)
        learned = learn_lead_minutes(state, v, settings, at(6, 25))
        self.assertEqual(learned, 30)
        self.assertEqual(clamp_lead(200), 30)
        self.assertEqual(clamp_lead(0.5), 5)

    def test_all_day_threshold_probe_and_gaps(self):
        settings = self.settings(
            allDay={
                "enabled": True,
                "days": [1],
                "from": "09:00",
                "until": "17:00",
                "limitC": 35,
                "solarOnlyAtHome": False,
                "dailyCapKWh": 10,
                "minSocPct": 20,
            },
        )
        state = default_state()
        inside = at(10, 0)
        d = all_day_decision(settings, vehicle(interiorC=40, at=at(9, 50).isoformat()), state, [], inside)
        self.assertTrue(d.fire)
        self.assertEqual(d.minutes, 10)
        state["lastBurst"] = {"at": inside.isoformat(), "reason": "allDay", "minutes": 10, "ok": True}
        self.assertFalse(all_day_decision(settings, vehicle(interiorC=40), state, [], at(10, 15)).fire)
        stale = at(11, 0)
        d_probe = all_day_decision(
            settings,
            vehicle(exteriorC=33, at=at(9, 0).isoformat()),
            state,
            [],
            stale,
        )
        self.assertTrue(d_probe.fire)

    def test_all_day_max_bursts_per_day(self):
        settings = self.settings(
            allDay={"enabled": True, "days": [1], "from": "09:00", "until": "17:00", "solarOnlyAtHome": False},
        )
        state = default_state()
        for i in range(12):
            state["log"].append(
                {"at": at(9, i).isoformat(), "action": "burst", "reason": "allDay"},
            )
        d = all_day_decision(settings, vehicle(interiorC=50, at=at(9, 50).isoformat()), state, [], at(10, 0))
        self.assertFalse(d.fire)

    def test_power_cap_and_min_soc(self):
        settings = self.settings(
            allDay={"enabled": True, "days": [1], "from": "09:00", "until": "17:00",
                    "solarOnlyAtHome": False, "dailyCapKWh": 0.1, "minSocPct": 50},
            assumedKW=2.0,
        )
        state = default_state()
        when = at(10, 0)
        v = vehicle(interiorC=40, soc=80, at=at(9, 50).isoformat())
        d = all_day_decision(settings, v, state, [], when)
        self.assertEqual(d.blocked, "daily cap")
        d2 = all_day_decision(settings, vehicle(interiorC=40, soc=40, at=at(9, 50).isoformat()), state, [], when)
        self.assertEqual(d2.blocked, "battery below 50%")

    def test_solar_rule_always_when_at_home_unknown(self):
        settings = self.settings(
            allDay={"enabled": True, "days": [1], "from": "09:00", "until": "17:00", "solarOnlyAtHome": True},
            assumedKW=2.0,
        )
        now = at(10, 0)
        short_export = [{"t": now.isoformat(), "supplyW": -1500}]
        strong_export = [{"t": now.isoformat(), "supplyW": -2500}]
        self.assertFalse(solar_surplus_ok(short_export, now, 2.0))
        self.assertTrue(solar_surplus_ok(strong_export, now, 2.0))
        d = all_day_decision(
            settings,
            vehicle(interiorC=40, at=at(9, 50).isoformat()),
            default_state(),
            short_export,
            now,
        )
        self.assertEqual(d.blocked, "no solar surplus")

    def test_departure_exempt_from_solar(self):
        settings = self.settings(
            departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24},
            allDay={"solarOnlyAtHome": True},
        )
        samples = [{"t": at(7, 45).isoformat(), "supplyW": 1000}]
        d = departure_decision(settings, vehicle(interiorC=40), default_state(), samples, at(7, 45))
        self.assertTrue(d.fire)
        self.assertIsNone(d.blocked)

    def test_climate_active_and_signed_out(self):
        settings = default_settings()
        signed = decide(settings, {"error": "signed out"}, default_state(), [], at(8, 0))
        self.assertEqual(signed.blocked, "signed out")
        active = decide(settings, vehicle(climateActive=True, interiorC=50), default_state(), [], at(8, 0))
        self.assertFalse(active.fire)

    def test_midnight_reset(self):
        state = default_state()
        state["today"] = "2026-11-15"
        state["todayKWh"] = 1.2
        out = normalize_state(state, at(8, 0))
        self.assertEqual(out["today"], "2026-11-16")
        self.assertEqual(out["todayKWh"], 0.0)

    def test_cool_now_respects_min_soc_not_solar(self):
        settings = self.settings(allDay={"minSocPct": 50, "solarOnlyAtHome": True})
        samples = [{"t": at(12, 0).isoformat(), "supplyW": 5000}]
        d = cool_now_decision(settings, vehicle(soc=40), default_state(), samples, at(12, 0), 10)
        self.assertEqual(d.blocked, "battery below 50%")
        d2 = cool_now_decision(settings, vehicle(soc=80), default_state(), samples, at(12, 0), 10)
        self.assertTrue(d2.fire)

    def test_duration_seconds_unit(self):
        self.assertEqual(duration_seconds(10), "600")

    def test_dry_run_never_calls_car(self):
        fired = []

        def fake_firer(decision: Decision, settings: dict) -> bool:
            fired.append(decision)
            return True

        with tempfile.TemporaryDirectory() as tmp:
            settings_path = f"{tmp}/climate.json"
            state_path = f"{tmp}/state.json"
            vehicle_path = f"{tmp}/vehicle.json"
            samples_path = f"{tmp}/samples.jsonl"
            lock_path = f"{tmp}/lock"
            import json

            settings = self.settings(
                departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24},
                allDay={"solarOnlyAtHome": False},
            )
            with open(settings_path, "w") as handle:
                json.dump(settings, handle)
            with open(vehicle_path, "w") as handle:
                json.dump(vehicle(interiorC=40), handle)
            with open(state_path, "w") as handle:
                json.dump(default_state(), handle)
            now = at(7, 45)
            rc = tick_once(
                now=now,
                dry_run=True,
                firer=fake_firer,
                settings_path=settings_path,
                state_path=state_path,
                vehicle_path=vehicle_path,
                samples_path=samples_path,
                lock_path=lock_path,
            )
            self.assertEqual(rc, 0)
            self.assertEqual(fired, [])
            rc2 = cool_now(
                10,
                dry_run=True,
                firer=fake_firer,
                settings_path=settings_path,
                state_path=state_path,
                vehicle_path=vehicle_path,
                samples_path=samples_path,
                lock_path=lock_path,
            )
            self.assertEqual(rc2, 0)
            self.assertEqual(fired, [])

    def test_idempotent_same_minute(self):
        calls = []

        def fake_firer(decision: Decision, settings: dict) -> bool:
            calls.append(1)
            return True

        with tempfile.TemporaryDirectory() as tmp:
            import json

            paths = {name: f"{tmp}/{name}" for name in ("climate.json", "state.json", "vehicle.json", "lock")}
            samples_path = f"{tmp}/samples.jsonl"
            settings = self.settings(
                departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24},
                allDay={"solarOnlyAtHome": False},
            )
            with open(paths["climate.json"], "w") as handle:
                json.dump(settings, handle)
            with open(paths["vehicle.json"], "w") as handle:
                json.dump(vehicle(interiorC=40), handle)
            with open(paths["state.json"], "w") as handle:
                json.dump(default_state(), handle)
            now = at(7, 45)
            tick_once(
                now=now,
                firer=fake_firer,
                settings_path=paths["climate.json"],
                state_path=paths["state.json"],
                vehicle_path=paths["vehicle.json"],
                samples_path=samples_path,
                lock_path=paths["lock"],
            )
            tick_once(
                now=now,
                firer=fake_firer,
                settings_path=paths["climate.json"],
                state_path=paths["state.json"],
                vehicle_path=paths["vehicle.json"],
                samples_path=samples_path,
                lock_path=paths["lock"],
            )
            self.assertEqual(len(calls), 1)


    def test_review_fixes(self):
        # A fresh "climate on" reading blocks; a stale one does not.
        cool = self.settings(departure={"enabled": True, "time": "08:00", "days": [1], "targetC": 24})
        fresh = vehicle(climateActive=True, interiorC=40, at=at(7, 40).isoformat())
        self.assertFalse(decide(cool, fresh, default_state(), [], at(7, 50)).fire)
        stale = vehicle(climateActive=True, interiorC=40, at=at(6, 0).isoformat())
        self.assertTrue(decide(cool, stale, default_state(), [], at(7, 50)).fire)
        # "Today only" does nothing while cool-all-day is switched off.
        off = self.settings(allDay={"enabled": False, "onDate": "2026-11-16", "limitC": 30,
                                    "solarOnlyAtHome": False})
        hot = vehicle(interiorC=45, at=at(12, 0).isoformat())
        self.assertFalse(decide(off, hot, default_state(), [], at(12, 10)).fire)
        on = self.settings(allDay={"enabled": True, "onDate": "2026-11-16", "limitC": 30,
                                   "solarOnlyAtHome": False})
        self.assertTrue(decide(on, hot, default_state(), [], at(12, 10)).fire)
        self.assertFalse(decide(on, hot, default_state(), [], at(12, 10, day=17)).fire)
        # A failed command waits 15 min before the next attempt.
        st = default_state(); st["lastFailedAt"] = at(12, 0).isoformat()
        self.assertEqual(decide(on, hot, st, [], at(12, 10)).blocked, "retrying after a failed command")
        self.assertTrue(decide(on, hot, st, [], at(12, 16)).fire)
        # No single command runs longer than 30 min, whatever is asked.
        self.assertEqual(duration_seconds(600), "1800")


if __name__ == "__main__":
    unittest.main()