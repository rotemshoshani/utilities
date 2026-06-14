import json
import os
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

import prompt_queue
from prompt_queue import (
    Controller,
    RunItem,
    apply_agent_override,
    build_prompt_argument_command,
    build_run_queue,
    build_worker_cd_command,
    consume_finish_current_sleep,
    default_work_base_dir,
    kill_tmux_session_if_exists,
    latest_runtime_dir,
    load_env_file,
    load_config,
    make_runtime_dir,
    paste_settle_seconds,
    read_prompt_queue,
    render_status,
    should_finish_current_sleep,
    should_stop_after_current,
    write_collected_prompts,
    write_prompt_queue,
)


class PromptQueueTests(unittest.TestCase):
    def test_load_config_reads_prompts_and_defaults(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            prompt_file = tmp_path / "file-prompt.md"
            prompt_file.write_text("Prompt from file")
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": "/tmp/project",
                        "command": "cdx",
                        "run_seconds": 2700,
                        "startup_wait_seconds": 12,
                        "ready_check_seconds": 30,
                        "ready_check_lines": 2,
                        "ready_markers": ["Ready", "done"],
                        "block_marker": "DO-NOT-PROCEED",
                        "block_check_lines": 12,
                        "capture_lines": 250,
                        "prompts": [
                            {"name": "inline prompt", "text": "Prompt from config"},
                            {"name": "lines prompt", "lines": ["First line", "Second line"]},
                            {"name": "file prompt", "file": "file-prompt.md"},
                        ],
                    }
                )
            )

            config = load_config(config_path)

            self.assertEqual(config.project_dir, Path("/tmp/project"))
            self.assertEqual(config.command, "cdx")
            self.assertEqual(config.run_seconds, 2700)
            self.assertEqual(config.startup_wait_seconds, 12)
            self.assertEqual(config.ready_check_seconds, 30)
            self.assertEqual(config.ready_check_lines, 2)
            self.assertEqual(config.ready_markers, ("Ready", "done"))
            self.assertEqual(config.block_marker, "DO-NOT-PROCEED")
            self.assertEqual(config.block_check_lines, 12)
            self.assertEqual(config.capture_lines, 250)
            self.assertEqual([(item.index, item.name, item.text) for item in config.prompts], [
                (1, "inline-prompt", "Prompt from config"),
                (2, "lines-prompt", "First line\nSecond line"),
                (3, "file-prompt", "Prompt from file"),
            ])

    def test_project_dir_resolves_relative_to_config_file(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            project_dir = tmp_path / "repo"
            project_dir.mkdir()
            config_path = tmp_path / "config.json"
            config_path.write_text(json.dumps({"project_dir": "repo", "prompts": ["prompt"]}))

            config = load_config(config_path)

            self.assertEqual(config.project_dir, project_dir)

    def test_prompts_string_that_points_to_file_raises_clear_error(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            prompts_dir = tmp_path / "prompts"
            prompts_dir.mkdir()
            (prompts_dir / "001-work.md").write_text("actual prompt body")
            config_path = tmp_path / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": "/tmp/project",
                        "prompts": ["prompts/001-work.md"],
                        "prompt_files": [],
                    }
                )
            )

            with self.assertRaisesRegex(ValueError, "Move file path 'prompts/001-work.md' to 'prompt_files'"):
                load_config(config_path)

    def test_project_dir_can_come_from_env_local(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            project_dir = tmp_path / "repo"
            project_dir.mkdir()
            config_path = tmp_path / "config.json"
            env_path = tmp_path / ".env.local"
            old_value = os.environ.get("PROMPT_QUEUE_WORKDIR")
            try:
                env_path.write_text(f"PROMPT_QUEUE_WORKDIR={project_dir}\n")
                config_path.write_text(json.dumps({"project_dir": "${PROMPT_QUEUE_WORKDIR}", "prompts": ["prompt"]}))

                config = load_config(config_path)

                self.assertEqual(config.project_dir, project_dir)
            finally:
                if old_value is None:
                    os.environ.pop("PROMPT_QUEUE_WORKDIR", None)
                else:
                    os.environ["PROMPT_QUEUE_WORKDIR"] = old_value

    def test_load_env_file_parses_export_and_quotes(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            env_path = Path(raw_dir) / ".env.local"
            old_value = os.environ.get("PROMPT_QUEUE_WORKDIR")
            try:
                env_path.write_text("export PROMPT_QUEUE_WORKDIR='/tmp/quoted repo'\n")

                loaded = load_env_file(env_path)

                self.assertEqual(loaded["PROMPT_QUEUE_WORKDIR"], "/tmp/quoted repo")
                self.assertEqual(os.environ["PROMPT_QUEUE_WORKDIR"], "/tmp/quoted repo")
            finally:
                if old_value is None:
                    os.environ.pop("PROMPT_QUEUE_WORKDIR", None)
                else:
                    os.environ["PROMPT_QUEUE_WORKDIR"] = old_value

    def test_prompt_queue_round_trips_to_json(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            config_path = Path(raw_dir) / "config.json"
            queue_path = Path(raw_dir) / "queue.json"
            config_path.write_text(json.dumps({"prompts": ["one", "two"]}))
            prompts = load_config(config_path).prompts

            write_prompt_queue(queue_path, prompts)

            self.assertEqual(read_prompt_queue(queue_path), prompts)

    def test_write_collected_prompts_writes_files_and_updates_config(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            config_path = Path(raw_dir) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": "/tmp/project",
                        "prompts": [{"name": "old", "text": "old"}],
                        "prompt_files": ["prompts/old.md"],
                    }
                )
            )

            written = write_collected_prompts(
                config_path,
                [("First prompt", "first body"), ("Second prompt", "second body")],
            )

            raw = json.loads(config_path.read_text())
            self.assertEqual(
                raw["prompts"],
                [
                    {"name": "First-prompt", "file": "prompts/001-First-prompt.md"},
                    {"name": "Second-prompt", "file": "prompts/002-Second-prompt.md"},
                ],
            )
            self.assertEqual(raw["prompt_files"], [])
            self.assertEqual([path.name for path in written], ["001-First-prompt.md", "002-Second-prompt.md"])
            self.assertEqual((Path(raw_dir) / "prompts/001-First-prompt.md").read_text(), "first body\n")

    def test_build_run_queue_runs_one_codex_instance_per_prompt(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            config_path = Path(raw_dir) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "command": "cdx",
                        "prompt_delivery": "argument_file",
                        "prompts": [
                            {"name": "first", "text": "Prompt one"},
                            {"name": "second", "text": "Prompt two"},
                        ],
                    }
                )
            )

            queue = build_run_queue(load_config(config_path))

            self.assertEqual(
                [(item.index, item.prompt_name, item.command, item.prompt_delivery) for item in queue],
                [
                    (1, "first", "cdx", "argument_file"),
                    (2, "second", "cdx", "argument_file"),
                ],
            )

    def test_cld_override_reuses_queue_with_claude_command_and_paste_delivery(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            config_path = Path(raw_dir) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "command": "cdx",
                        "prompt_delivery": "argument_file",
                        "prompts": [{"name": "first", "text": "Prompt one"}],
                    }
                )
            )

            config = apply_agent_override(load_config(config_path), use_claude=True)
            queue = build_run_queue(config)

            self.assertEqual(config.command, "cld")
            self.assertEqual(config.prompt_delivery, "paste")
            self.assertEqual([(item.prompt_name, item.command, item.prompt_delivery) for item in queue], [
                ("first", "cld", "paste")
            ])

    def test_agent_override_leaves_default_codex_config_unchanged(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            config_path = Path(raw_dir) / "config.json"
            config_path.write_text(json.dumps({"command": "cdx", "prompt_delivery": "argument_file", "prompts": ["one"]}))
            config = load_config(config_path)

            self.assertIs(apply_agent_override(config, use_claude=False), config)

    def test_render_status_marks_done_in_progress_pending_and_stop_next(self) -> None:
        queue = [
            RunItem(index=1, prompt_name="first", prompt_text="one", prompt_source="test", command="cdx"),
            RunItem(index=2, prompt_name="second", prompt_text="two", prompt_source="test", command="cdx"),
            RunItem(index=3, prompt_name="third", prompt_text="three", prompt_source="test", command="cdx"),
        ]

        status = render_status(queue, current_index=2, completed={1}, stop_after_current=True)

        self.assertIn("first #1 ... V", status)
        self.assertIn("second #2 ... in progress", status)
        self.assertIn("third #3 ... queued", status)
        self.assertIn("[S] stop after current: armed", status)
        self.assertIn("[F] finish current sleep", status)

    def test_should_stop_after_current_reads_flag_file(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            runtime_dir = Path(raw_dir) / "runtime"
            runtime_dir.mkdir()

            self.assertFalse(should_stop_after_current(runtime_dir))

            (runtime_dir / "stop-next.flag").write_text("1")

            self.assertTrue(should_stop_after_current(runtime_dir))

    def test_finish_current_sleep_flag_is_consumed(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            runtime_dir = Path(raw_dir) / "runtime"
            runtime_dir.mkdir()

            self.assertFalse(should_finish_current_sleep(runtime_dir))
            self.assertFalse(consume_finish_current_sleep(runtime_dir))

            flag = runtime_dir / "finish-sleep.flag"
            flag.write_text("1")

            self.assertTrue(should_finish_current_sleep(runtime_dir))
            self.assertTrue(consume_finish_current_sleep(runtime_dir))
            self.assertFalse(flag.exists())

    def test_build_worker_cd_command_quotes_project_path(self) -> None:
        command = build_worker_cd_command(Path("/tmp/project with 'quote'"))

        self.assertEqual(command, "cd -- '/tmp/project with '\"'\"'quote'\"'\"''")

    def test_build_prompt_argument_command_reads_prompt_file_as_single_argument(self) -> None:
        command = build_prompt_argument_command("cdx", Path("/tmp/project prompt.txt"))

        self.assertEqual(command, 'cdx "$(cat \'/tmp/project prompt.txt\')"')

    def test_paste_settle_seconds_scales_by_prompt_size(self) -> None:
        self.assertEqual(paste_settle_seconds(499), 1.5)
        self.assertEqual(paste_settle_seconds(500), 2.5)
        self.assertEqual(paste_settle_seconds(5000), 4.0)
        self.assertEqual(paste_settle_seconds(20000), 6.0)

    def test_paste_prompt_uses_tmux_bracketed_paste_and_sends_enter(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            config_path.write_text(json.dumps({"project_dir": "/tmp/project", "prompts": ["prompt"]}))
            config = load_config(config_path, runtime_dir_override=tmp_path / "runtime")
            controller = Controller(config, "session", "%1")
            prompt_file = tmp_path / "prompt.txt"
            prompt_file.write_text("hello\n\n")
            calls: list[tuple[tuple[str, ...], str | None]] = []

            def fake_tmux(*args: str, **kwargs: object) -> CompletedProcess[str]:
                calls.append((args, kwargs.get("input_text") if isinstance(kwargs.get("input_text"), str) else None))
                return CompletedProcess(["tmux", *args], 0, "", "")

            with mock.patch.object(prompt_queue, "tmux", side_effect=fake_tmux), mock.patch.object(prompt_queue.time, "sleep"):
                controller.paste_prompt(prompt_file)

            self.assertEqual(calls[0], (("load-buffer", "-b", mock.ANY, "-"), "hello"))
            self.assertEqual(calls[1][0][:6], ("paste-buffer", "-d", "-p", "-b", mock.ANY, "-t"))
            self.assertEqual(calls[1][0][6:], ("%1",))
            self.assertEqual(calls[2], (("send-keys", "-t", "%1", "Enter"), None))

    def test_kill_tmux_session_if_exists_kills_existing_session(self) -> None:
        calls: list[tuple[str, ...]] = []

        def fake_tmux(*args: str, **kwargs: object) -> CompletedProcess[str]:
            calls.append(args)
            if args[:1] == ("has-session",):
                return CompletedProcess(["tmux", *args], 0, "", "")
            return CompletedProcess(["tmux", *args], 0, "", "")

        with mock.patch.object(prompt_queue, "tmux", side_effect=fake_tmux):
            killed = kill_tmux_session_if_exists("prompt-queue-project")

        self.assertTrue(killed)
        self.assertEqual(calls, [
            ("has-session", "-t", "prompt-queue-project"),
            ("kill-session", "-t", "prompt-queue-project"),
        ])

    def test_kill_tmux_session_if_exists_skips_missing_session(self) -> None:
        calls: list[tuple[str, ...]] = []

        def fake_tmux(*args: str, **kwargs: object) -> CompletedProcess[str]:
            calls.append(args)
            return CompletedProcess(["tmux", *args], 1, "", "")

        with mock.patch.object(prompt_queue, "tmux", side_effect=fake_tmux):
            killed = kill_tmux_session_if_exists("prompt-queue-project")

        self.assertFalse(killed)
        self.assertEqual(calls, [("has-session", "-t", "prompt-queue-project")])

    def test_ready_marker_blocks_on_exact_marker_line_only(self) -> None:
        from tempfile import TemporaryDirectory

        class FakeController(Controller):
            def __init__(self, *args: object) -> None:
                super().__init__(*args)
                self.calls = 0

            def capture_worker_tail(self, lines: int) -> str:
                self.calls += 1
                if self.calls == 1:
                    return "gpt status Ready\n"
                return "This mentions DO-NOT-PROCEED but is not exact\nDO-NOT-PROCEED\nReady\n"

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": "/tmp/project",
                        "ready_check_lines": 1,
                        "block_marker": "DO-NOT-PROCEED",
                        "block_check_lines": 10,
                        "prompts": ["prompt"],
                    }
                )
            )
            config = load_config(config_path, runtime_dir_override=tmp_path / "runtime")
            controller = FakeController(config, "session", "%1")
            controller.ready_check_dir.mkdir(parents=True)

            result = controller.check_ready_marker(
                RunItem(index=1, prompt_name="prompt-1", prompt_text="prompt", prompt_source="test", command="cdx")
            )

            self.assertEqual(result, "blocked")
            self.assertTrue(controller.block_detected)
            self.assertEqual(controller.block_marker_line, "DO-NOT-PROCEED")

    def test_ready_marker_ignores_non_exact_block_marker_mentions(self) -> None:
        from tempfile import TemporaryDirectory

        class FakeController(Controller):
            def __init__(self, *args: object) -> None:
                super().__init__(*args)
                self.calls = 0

            def capture_worker_tail(self, lines: int) -> str:
                self.calls += 1
                if self.calls == 1:
                    return "gpt status Ready\n"
                return "This mentions DO-NOT-PROCEED but is not exact\nReady\n"

        with TemporaryDirectory() as raw_dir:
            tmp_path = Path(raw_dir)
            config_path = tmp_path / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "project_dir": "/tmp/project",
                        "ready_check_lines": 1,
                        "block_marker": "DO-NOT-PROCEED",
                        "block_check_lines": 10,
                        "prompts": ["prompt"],
                    }
                )
            )
            config = load_config(config_path, runtime_dir_override=tmp_path / "runtime")
            controller = FakeController(config, "session", "%1")
            controller.ready_check_dir.mkdir(parents=True)

            result = controller.check_ready_marker(
                RunItem(index=1, prompt_name="prompt-1", prompt_text="prompt", prompt_source="test", command="cdx")
            )

            self.assertEqual(result, "ready")
            self.assertFalse(controller.block_detected)

    def test_default_work_base_dir_lives_under_project_planning_work(self) -> None:
        self.assertEqual(
            default_work_base_dir(Path("/repo")),
            Path("/repo/.planning/work/prompt-queue"),
        )

    def test_make_runtime_dir_uses_start_timestamp_under_work_base(self) -> None:
        self.assertEqual(
            make_runtime_dir(Path("/repo"), "20260526-175900"),
            Path("/repo/.planning/work/prompt-queue/20260526-175900"),
        )

    def test_latest_runtime_dir_finds_newest_timestamped_run(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as raw_dir:
            project_dir = Path(raw_dir) / "project"
            older = project_dir / ".planning/work/prompt-queue/20260526-100000"
            newer = project_dir / ".planning/work/prompt-queue/20260526-110000"
            older.mkdir(parents=True)
            newer.mkdir(parents=True)
            (older / "session.json").write_text("{}")
            (newer / "session.json").write_text("{}")

            self.assertEqual(latest_runtime_dir(project_dir), newer)


if __name__ == "__main__":
    unittest.main()
