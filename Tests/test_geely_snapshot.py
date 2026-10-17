import datetime as dt
import unittest

from tools.geely_snapshot import snapshot_cache


class SnapshotTests(unittest.TestCase):
    checked = "2026-10-17T05:00:00+00:00"
    measured = int(dt.datetime(2026, 10, 17, 4, 58, tzinfo=dt.timezone.utc).timestamp() * 1000)

    def payload(self, soc="64", updated=None):
        return {"data": {"vehicleStatus": {
            "updateTime": self.measured if updated is None else updated,
            "additionalVehicleStatus": {"electricVehicleStatus": {
                "chargeLevel": soc, "distanceToEmptyOnBatteryOnly": "51"}}}}}

    def test_source_time_preserved_across_repeated_checks(self):
        one = snapshot_cache(self.payload(), checked_at=self.checked)
        two = snapshot_cache(self.payload(), checked_at="2026-10-17T07:00:00+00:00")
        self.assertEqual(one["at"], "2026-10-17T04:58:00+00:00")
        self.assertEqual(one["at"], two["at"])
        self.assertNotEqual(one["checkedAt"], two["checkedAt"])
        self.assertEqual(one["soc"], 64)
        self.assertEqual(one["rangeKm"], 51)

    def test_unknown_time_never_becomes_now(self):
        bad_times = ["", "garbled", True, False, 0, 1780000000, float("nan"), float("inf"), 1e100, self.measured + 3600000]
        for value in bad_times:
            with self.subTest(value=value):
                out = snapshot_cache(self.payload(updated=value), checked_at=self.checked)
                self.assertNotIn("at", out)
                self.assertNotIn("soc", out)
                self.assertIn("error", out)
        p = self.payload()
        del p["data"]["vehicleStatus"]["updateTime"]
        self.assertNotIn("at", snapshot_cache(p, checked_at=self.checked))

    def test_supported_top_level_time(self):
        p = self.payload()
        p["data"]["updateTime"] = str(p["data"]["vehicleStatus"].pop("updateTime"))
        self.assertEqual(snapshot_cache(p, checked_at=self.checked)["soc"], 64)

    def test_invalid_battery_and_range(self):
        for soc in [True, False, None, "NaN", "inf", -1, 101, {}, []]:
            out = snapshot_cache(self.payload(soc=soc), checked_at=self.checked)
            self.assertNotIn("soc", out)
            self.assertIn("error", out)
        for soc in [0, 100]:
            self.assertEqual(snapshot_cache(self.payload(soc=soc), checked_at=self.checked)["soc"], soc)
        p = self.payload()
        p["data"]["vehicleStatus"]["additionalVehicleStatus"]["electricVehicleStatus"]["distanceToEmptyOnBatteryOnly"] = "NaN"
        self.assertNotIn("rangeKm", snapshot_cache(p, checked_at=self.checked))

    def test_malformed_response(self):
        for value in [None, [], "error", {}, {"data": {"vehicleStatus": []}}]:
            self.assertIn("error", snapshot_cache(value, checked_at=self.checked))


if __name__ == "__main__":
    unittest.main()
