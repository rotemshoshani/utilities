from datetime import date, datetime, timezone
import unittest

from pomodoro_tui.stats import StatsStore, WorkEvent


class StatsTests(unittest.TestCase):
    def test_totals_and_streaks(self):
        with self.subTest():
            store = StatsStore()
            store.events = [
                WorkEvent(datetime(2026, 5, 4, 12, tzinfo=timezone.utc), 10, 1),
                WorkEvent(datetime(2026, 5, 5, 12, tzinfo=timezone.utc), 10, 1),
                WorkEvent(datetime(2026, 5, 6, 12, tzinfo=timezone.utc), 10, 1),
            ]

            self.assertEqual(store.totals()["points"], 3)
            self.assertEqual(store.daily_streak(date(2026, 5, 6)), 3)
            self.assertEqual(store.weekly_streak(date(2026, 5, 6)), 1)

    def test_record_work_cut_minutes_mode(self):
        with self.subTest():
            import tempfile
            from pathlib import Path

            with tempfile.TemporaryDirectory() as tmp:
                store = StatsStore(Path(tmp) / "stats.json")

                event = store.record_work_cut(10, "minutes")

                self.assertEqual(event.points, 10)
                self.assertEqual(store.totals()["work_minutes"], 10)


if __name__ == "__main__":
    unittest.main()
