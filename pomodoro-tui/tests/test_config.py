import unittest

from pomodoro_tui.config import AppConfig, parse_work_spec


class ConfigTests(unittest.TestCase):
    def test_parse_work_spec_defaults_to_one_cut(self):
        self.assertEqual(parse_work_spec("25"), (25.0, 1))

    def test_parse_work_spec_accepts_cut_count(self):
        self.assertEqual(parse_work_spec("10x5"), (10.0, 5))

    def test_parse_work_spec_rejects_bad_values(self):
        with self.assertRaises(ValueError):
            parse_work_spec("x10")

    def test_app_config_from_values(self):
        config = AppConfig.from_values("10x5", 10, "minutes")

        self.assertEqual(config.work_minutes, 10)
        self.assertEqual(config.work_cuts, 5)
        self.assertEqual(config.rest_minutes, 10)
        self.assertEqual(config.point_mode, "minutes")


if __name__ == "__main__":
    unittest.main()
