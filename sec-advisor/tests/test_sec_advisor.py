import json
import unittest
from pathlib import Path

from sec_advisor import (
    RunItem,
    build_run_queue,
    build_worker_cd_command,
    default_work_base_dir,
    latest_runtime_dir,
    load_config,
    make_runtime_dir,
    render_prompt,
    render_status,
    should_stop_after_current,
)


class SecAdvisorTests(unittest.TestCase):
    def test_load_config_reads_defaults_and_agent_commands(self) -> None:
        with self.subTest():
            from tempfile import TemporaryDirectory

            with TemporaryDirectory() as raw_dir:
                tmp_path = Path(raw_dir)
                config_path = tmp_path / "config.json"
                config_path.write_text(
                    json.dumps(
                        {
                            "project_dir": "/tmp/project",
                            "num_runs": 2,
                            "run_seconds": 3600,
                            "startup_wait_seconds": 12,
                            "capture_lines": 250,
                            "agents": [
                                {
                                    "name": "claude",
                                    "command": "claude --dangerously-skip-permissions --model default",
                                },
                                {
                                    "name": "codex",
                                    "command": "codex --bypass-permissions-and-sandboxes",
                                },
                            ],
                        }
                    )
                )

                config = load_config(config_path)

                self.assertEqual(config.project_dir, Path("/tmp/project"))
                self.assertEqual(config.num_runs, 2)
                self.assertEqual(config.run_seconds, 3600)
                self.assertEqual(config.startup_wait_seconds, 12)
                self.assertEqual(config.capture_lines, 250)
                self.assertEqual([agent.name for agent in config.agents], ["claude", "codex"])

    def test_build_run_queue_repeats_each_agent_for_num_runs(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "num_runs": 2,
                        "agents": [
                            {"name": "claude", "command": "claude --model default"},
                            {"name": "codex", "command": "codex"},
                        ],
                    }
                )
            )

            queue = build_run_queue(load_config(config_path))

            self.assertEqual(
                [(item.index, item.agent_name, item.command) for item in queue],
                [
                    (1, "claude", "claude --model default"),
                    (2, "codex", "codex"),
                    (3, "claude", "claude --model default"),
                    (4, "codex", "codex"),
                ],
            )

    def test_render_status_marks_done_in_progress_pending_and_stop_next(self) -> None:
        queue = [
            RunItem(index=1, cycle=1, agent_name="claude", command="claude"),
            RunItem(index=2, cycle=1, agent_name="codex", command="codex"),
            RunItem(index=3, cycle=2, agent_name="claude", command="claude"),
        ]

        status = render_status(queue, current_index=2, completed={1}, stop_after_current=True)

        self.assertIn("claude #1 ... V", status)
        self.assertIn("codex #2 ... in progress", status)
        self.assertIn("claude #3 ... queued", status)
        self.assertIn("[S] stop after current: armed", status)

    def test_should_stop_after_current_reads_flag_file(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            runtime_dir = Path(raw_dir) / "runtime"
            runtime_dir.mkdir()

            self.assertFalse(should_stop_after_current(runtime_dir))

            (runtime_dir / "stop-next.flag").write_text("1")

            self.assertTrue(should_stop_after_current(runtime_dir))

    def test_invalid_config_rejects_missing_agents(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            config_path.write_text(json.dumps({"num_runs": 2, "agents": []}))

            with self.assertRaisesRegex(ValueError, "agents"):
                load_config(config_path)

    def test_project_dir_override_replaces_configured_project_dir(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            configured = tmp_path / "configured"
            override = tmp_path / "override"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": str(configured),
                        "agents": [{"name": "claude", "command": "claude"}],
                    }
                )
            )

            config = load_config(config_path, project_dir_override=override)

            self.assertEqual(config.project_dir, override)

    def test_relative_project_dir_resolves_from_current_working_dir(self) -> None:
        from tempfile import TemporaryDirectory
        from unittest.mock import patch

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            work_dir = tmp_path / "work"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": ".",
                        "agents": [{"name": "claude", "command": "claude"}],
                    }
                )
            )

            with patch("sec_advisor.Path.cwd", return_value=work_dir):
                config = load_config(config_path)

            self.assertEqual(config.project_dir, work_dir)

    def test_build_worker_cd_command_quotes_project_path(self) -> None:
        command = build_worker_cd_command(Path("/tmp/project with 'quote'"))

        self.assertEqual(command, "cd -- '/tmp/project with '\"'\"'quote'\"'\"''")

    def test_default_work_base_dir_lives_under_project_planning_work(self) -> None:
        self.assertEqual(
            default_work_base_dir(Path("/repo")),
            Path("/repo/.planning/work/sec-advisor"),
        )

    def test_make_runtime_dir_uses_start_timestamp_under_work_base(self) -> None:
        self.assertEqual(
            make_runtime_dir(Path("/repo"), "20260526-175900"),
            Path("/repo/.planning/work/sec-advisor/20260526-175900"),
        )

    def test_render_prompt_uses_timestamped_runtime_as_audit_dir(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            project_dir = tmp_path / "project"
            runtime_dir = project_dir / ".planning/work/sec-advisor/20260526-175900"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": str(project_dir),
                        "agents": [{"name": "claude", "command": "claude"}],
                        "prompt": "audit={audit_dir} runtime={runtime_dir}",
                    }
                )
            )

            config = load_config(config_path, runtime_dir_override=runtime_dir)
            prompt = render_prompt(
                config.prompt,
                config,
                RunItem(index=1, cycle=1, agent_name="claude", command="claude"),
            )

            self.assertIn(f"audit={runtime_dir}", prompt)
            self.assertIn(f"runtime={runtime_dir}", prompt)

    def test_latest_runtime_dir_finds_newest_timestamped_run(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            project_dir = Path(raw_dir) / "project"
            older = project_dir / ".planning/work/sec-advisor/20260526-100000"
            newer = project_dir / ".planning/work/sec-advisor/20260526-110000"
            older.mkdir(parents=True)
            newer.mkdir(parents=True)
            (older / "session.json").write_text("{}")
            (newer / "session.json").write_text("{}")

            self.assertEqual(latest_runtime_dir(project_dir), newer)


if __name__ == "__main__":
    unittest.main()
