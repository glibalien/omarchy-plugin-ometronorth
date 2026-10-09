"""End-to-end route selection against a small, local GTFS-RT feed."""

import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "bin" / "mnr-panel"


def varint(n):
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint((number << 3) | 2) + varint(len(value)) + value


def stop(stop_id, arrival, departure):
    return (field(4, stop_id)
            + field(2, field(2, arrival))
            + field(3, field(2, departure)))


def trip(trip_id, stops):
    descriptor = field(1, trip_id) + field(5, "2")
    update = field(1, descriptor) + b"".join(field(2, s) for s in stops)
    return field(2, field(3, update))


class AnywhereRoutes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        now = int(time.time())
        cls.tmp = tempfile.TemporaryDirectory()
        feed = (
            trip("outbound-early", [
                stop("1", now + 120, now + 120),
                stop("4", now + 600, now + 600),
                stop("74", now + 1800, now + 1800),
            ])
            + trip("outbound-later", [
                stop("1", now + 300, now + 300),
                stop("4", now + 900, now + 900),
                stop("71", now + 1500, now + 1500),
            ])
            + trip("approaching", [
                stop("56", now - 600, now - 600),
                stop("74", now + 240, now + 240),
                stop("76", now + 720, now + 720),
            ])
            + trip("past", [
                stop("56", now - 1200, now - 1200),
                stop("74", now - 300, now - 300),
            ])
        )
        cls.url = Path(cls.tmp.name, "feed.pb").as_uri()
        Path(cls.tmp.name, "feed.pb").write_bytes(feed)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def report(self, frm, to):
        result = subprocess.run(
            [str(SCRIPT), "--from", frm, "--to", to, "--url", self.url],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    def test_fixed_origin_lists_each_outbound_train_once_with_destination(self):
        report = self.report("Grand Central", "Anywhere")
        self.assertTrue(report["ok"])
        self.assertEqual([t["tripId"] for t in report["trips"]],
                         ["outbound-early", "outbound-later"])
        self.assertEqual([t["toName"] for t in report["trips"]],
                         ["White Plains", "Scarsdale"])

    def test_fixed_destination_includes_en_route_train_and_sorts_by_arrival(self):
        report = self.report("Anywhere", "White Plains")
        self.assertTrue(report["ok"])
        self.assertEqual([t["tripId"] for t in report["trips"]],
                         ["approaching", "outbound-early"])
        self.assertEqual([t["fromName"] for t in report["trips"]],
                         ["Fordham", "Grand Central"])

    def test_station_pair_still_only_lists_trains_serving_both_stops(self):
        report = self.report("Grand Central", "White Plains")
        self.assertTrue(report["ok"])
        self.assertEqual([t["tripId"] for t in report["trips"]],
                         ["outbound-early"])

    def test_both_anywhere_has_a_clear_error(self):
        report = self.report("Anywhere", "Anywhere")
        self.assertFalse(report["ok"])
        self.assertIn("one station", report["error"])


if __name__ == "__main__":
    unittest.main()
