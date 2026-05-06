import unittest

from pomodoro_tui.config import AppConfig
from pomodoro_tui.timer import IntervalKind, PomodoroTimer, format_seconds


class TimerTests(unittest.TestCase):
    def test_timer_advances_through_work_cuts_then_rest(self):
        timer = PomodoroTimer(AppConfig(work_minutes=0.1, work_cuts=2, rest_minutes=0.1))

        self.assertEqual(timer.interval.kind, IntervalKind.WORK)
        self.assertEqual(timer.interval.cut_number, 1)

        completed = timer.advance()
        self.assertEqual(completed.kind, IntervalKind.WORK)
        self.assertEqual(timer.interval.kind, IntervalKind.WORK)
        self.assertEqual(timer.interval.cut_number, 2)

        timer.advance()
        self.assertEqual(timer.interval.kind, IntervalKind.REST)

        timer.advance()
        self.assertEqual(timer.interval.kind, IntervalKind.WORK)
        self.assertEqual(timer.interval.cut_number, 1)

    def test_tick_respects_pause(self):
        timer = PomodoroTimer(AppConfig(work_minutes=1, work_cuts=1, rest_minutes=1))
        timer.toggle_pause()

        self.assertFalse(timer.tick(60))
        self.assertEqual(timer.remaining_seconds, 60)

    def test_format_seconds(self):
        self.assertEqual(format_seconds(65), "01:05")
        self.assertEqual(format_seconds(3661), "1:01:01")


if __name__ == "__main__":
    unittest.main()
