#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path


DEFAULT_CONFIG = Path(__file__).with_name("config.json")
DEFAULT_ENV = Path(__file__).with_name(".env.local")
STOP_NEXT_FLAG = "stop-next.flag"
FINISH_SLEEP_FLAG = "finish-sleep.flag"
TIMESTAMP_FORMAT = "%Y%m%d-%H%M%S"
NO_MORE_PROMPTS = "no more prompts"
DEFAULT_PROMPT_END_MARKER = "::end"
DEFAULT_BLOCK_MARKER = "DO-NOT-PROCEED"
WORKDIR_ENV_KEY = "PROMPT_QUEUE_WORKDIR"
DEFAULT_CODEX_COMMAND = "cdx"
DEFAULT_CLAUDE_COMMAND = "cld"
DEFAULT_CODEX_PROMPT_DELIVERY = "argument_file"
DEFAULT_CLAUDE_PROMPT_DELIVERY = "paste"


@dataclass(frozen=True)
class PromptItem:
    index: int
    name: str
    text: str
    source: str = "config"


@dataclass(frozen=True)
class Config:
    project_dir: Path
    runtime_dir: Path
    session_name: str
    command: str
    run_seconds: int
    startup_wait_seconds: int
    capture_lines: int
    history_limit: int
    prompt_delivery: str
    ready_check_seconds: int
    ready_check_lines: int
    ready_markers: tuple[str, ...]
    block_marker: str
    block_check_lines: int
    prompts: tuple[PromptItem, ...]


@dataclass(frozen=True)
class RunItem:
    index: int
    prompt_name: str
    prompt_text: str
    prompt_source: str
    command: str
    prompt_delivery: str = "argument_file"


def expand_project_path(value: str, base_dir: Path) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if not path.is_absolute():
        path = base_dir / path
    return path.resolve()


def load_env_file(path: Path) -> dict[str, str]:
    path = path.expanduser()
    if not path.exists():
        return {}

    loaded: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            raise ValueError(f"{path}:{line_number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"{path}:{line_number}: empty env key")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        loaded[key] = value
        os.environ[key] = value
    return loaded


def load_config(
    path: Path = DEFAULT_CONFIG,
    project_dir_override: Path | None = None,
    runtime_dir_override: Path | None = None,
) -> Config:
    path = path.expanduser().resolve()
    load_env_file(path.with_name(DEFAULT_ENV.name))
    raw = json.loads(path.read_text())
    base_dir = path.parent

    raw_project_dir = str(raw.get("project_dir", f"${{{WORKDIR_ENV_KEY}}}"))
    project_dir = (
        project_dir_override.expanduser().resolve()
        if project_dir_override is not None
        else expand_project_path(raw_project_dir, base_dir)
    )
    runtime_dir = runtime_dir_override if runtime_dir_override is not None else make_runtime_dir(project_dir)
    prompts = tuple(load_config_prompts(raw, base_dir))

    ready_markers = raw.get("ready_markers", ["Ready"])
    if isinstance(ready_markers, str):
        ready_marker_values = (ready_markers,)
    elif isinstance(ready_markers, list):
        ready_marker_values = tuple(str(marker) for marker in ready_markers if str(marker))
    else:
        raise ValueError("ready_markers must be a string or an array of strings")

    return Config(
        project_dir=project_dir,
        runtime_dir=runtime_dir,
        session_name=str(raw.get("session_name", "prompt-queue")),
        command=str(raw.get("command", DEFAULT_CODEX_COMMAND)),
        run_seconds=int(raw.get("run_seconds", 2700)),
        startup_wait_seconds=int(raw.get("startup_wait_seconds", 10)),
        capture_lines=int(raw.get("capture_lines", 800)),
        history_limit=int(raw.get("history_limit", 200000)),
        prompt_delivery=str(raw.get("prompt_delivery", DEFAULT_CODEX_PROMPT_DELIVERY)),
        ready_check_seconds=int(raw.get("ready_check_seconds", 60)),
        ready_check_lines=int(raw.get("ready_check_lines", 1)),
        ready_markers=ready_marker_values,
        block_marker=str(raw.get("block_marker", DEFAULT_BLOCK_MARKER)),
        block_check_lines=int(raw.get("block_check_lines", 10)),
        prompts=prompts,
    )


def load_config_prompts(raw: dict[str, object], base_dir: Path) -> list[PromptItem]:
    loaded: list[tuple[str, str, str]] = []

    for item in raw.get("prompts", []):
        if isinstance(item, str):
            if looks_like_prompt_file_reference(item, base_dir):
                raise ValueError(
                    "config error: string entries in 'prompts' are sent as literal prompt text. "
                    f"Move file path {item!r} to 'prompt_files' or use an object with a 'file' key."
                )
            loaded.append((f"prompt-{len(loaded) + 1}", item, "config"))
        elif isinstance(item, dict):
            name = str(item.get("name", f"prompt-{len(loaded) + 1}"))
            if "file" in item:
                file_path = expand_path(str(item["file"]), base_dir)
                loaded.append((name or file_path.stem, file_path.read_text(), str(file_path)))
            elif "lines" in item:
                lines = item["lines"]
                if not isinstance(lines, list):
                    raise ValueError("prompt lines must be an array of strings")
                loaded.append((name, "\n".join(str(line) for line in lines), "config"))
            else:
                loaded.append((name, str(item.get("text", "")), "config"))
        else:
            raise ValueError("prompts entries must be strings or objects")

    for file_value in raw.get("prompt_files", []):
        file_path = expand_path(str(file_value), base_dir)
        loaded.append((file_path.stem, file_path.read_text(), str(file_path)))

    return normalize_prompt_items(loaded)


def looks_like_prompt_file_reference(value: str, base_dir: Path) -> bool:
    stripped = value.strip()
    if not stripped or any(ch.isspace() for ch in stripped):
        return False
    suffix = Path(stripped).suffix.lower()
    if suffix not in {".md", ".txt", ".markdown"}:
        return False
    path = expand_path(stripped, base_dir)
    return path.exists()


def expand_path(value: str, base_dir: Path) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if not path.is_absolute():
        path = base_dir / path
    return path


def normalize_prompt_items(items: list[tuple[str, str, str]]) -> list[PromptItem]:
    prompts: list[PromptItem] = []
    for raw_name, text, source in items:
        stripped = text.strip()
        if not stripped:
            continue
        prompts.append(
            PromptItem(
                index=len(prompts) + 1,
                name=sanitize_name(raw_name) or f"prompt-{len(prompts) + 1}",
                text=stripped,
                source=source,
            )
        )
    return prompts


def write_prompt_queue(path: Path, prompts: tuple[PromptItem, ...]) -> None:
    write_json(
        path,
        [
            {"index": item.index, "name": item.name, "text": item.text, "source": item.source}
            for item in prompts
        ],
    )


def read_prompt_queue(path: Path) -> tuple[PromptItem, ...]:
    raw = json.loads(path.read_text())
    return tuple(
        PromptItem(
            index=int(item["index"]),
            name=str(item["name"]),
            text=str(item["text"]),
            source=str(item.get("source", "queue")),
        )
        for item in raw
    )


def build_run_queue(config: Config) -> list[RunItem]:
    return [
        RunItem(
            index=prompt.index,
            prompt_name=prompt.name,
            prompt_text=prompt.text,
            prompt_source=prompt.source,
            command=config.command,
            prompt_delivery=config.prompt_delivery,
        )
        for prompt in config.prompts
    ]


def default_work_base_dir(project_dir: Path) -> Path:
    return project_dir / ".planning" / "work" / "prompt-queue"


def make_runtime_dir(project_dir: Path, timestamp: str | None = None) -> Path:
    stamp = timestamp or datetime.now().strftime(TIMESTAMP_FORMAT)
    return default_work_base_dir(project_dir) / stamp


def latest_runtime_dir(project_dir: Path) -> Path:
    base_dir = default_work_base_dir(project_dir)
    candidates = sorted(path for path in base_dir.iterdir() if path.is_dir()) if base_dir.exists() else []
    candidates = [path for path in candidates if (path / "session.json").exists() or (path / "state.json").exists()]
    if not candidates:
        raise SystemExit(f"no prompt-queue runs found under {base_dir}")
    return candidates[-1]


def build_worker_cd_command(project_dir: Path) -> str:
    return f"cd -- {sh_quote(str(project_dir))}"


def build_prompt_argument_command(command: str, prompt_file: Path) -> str:
    return f"{command} \"$(cat {sh_quote(str(prompt_file))})\""


def apply_agent_override(config: Config, use_claude: bool) -> Config:
    if not use_claude:
        return config
    return replace(
        config,
        command=DEFAULT_CLAUDE_COMMAND,
        prompt_delivery=DEFAULT_CLAUDE_PROMPT_DELIVERY,
    )


def paste_settle_seconds(text_length: int) -> float:
    if text_length < 500:
        return 1.5
    if text_length < 5000:
        return 2.5
    if text_length < 20000:
        return 4.0
    return 6.0


def should_stop_after_current(runtime_dir: Path) -> bool:
    return (runtime_dir / STOP_NEXT_FLAG).exists()


def should_finish_current_sleep(runtime_dir: Path) -> bool:
    return (runtime_dir / FINISH_SLEEP_FLAG).exists()


def consume_finish_current_sleep(runtime_dir: Path) -> bool:
    flag = runtime_dir / FINISH_SLEEP_FLAG
    if not flag.exists():
        return False
    flag.unlink(missing_ok=True)
    return True


def render_status(
    queue: list[RunItem],
    current_index: int | None,
    completed: set[int],
    stop_after_current: bool,
    phase: str = "idle",
    remaining_seconds: int | None = None,
) -> str:
    lines = ["prompt-queue", ""]
    for item in queue:
        if item.index in completed:
            marker = "V"
        elif current_index == item.index:
            marker = "in progress"
        else:
            marker = "queued"
        lines.append(f"{item.prompt_name} #{item.index} ... {marker}")

    lines.extend(["", f"phase: {phase}"])
    if remaining_seconds is not None:
        lines.append(f"sleep remaining: {format_duration(remaining_seconds)}")
    lines.append(f"[S] stop after current: {'armed' if stop_after_current else 'off'}")
    lines.append("[F] finish current sleep")
    lines.append("[Q] kill now")
    return "\n".join(lines)


def format_duration(seconds: int) -> str:
    minutes, sec = divmod(max(0, seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {sec}s"
    if minutes:
        return f"{minutes}m {sec}s"
    return f"{sec}s"


def sanitize_name(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in value).strip("-")
    return cleaned or "prompt"


def tmux(
    *args: str,
    check: bool = True,
    capture: bool = False,
    cwd: Path | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["tmux", *args],
        cwd=str(cwd) if cwd else None,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=check,
    )


def tmux_target_exists(target: str) -> bool:
    return tmux("display-message", "-p", "-t", target, "#{pane_id}", check=False, capture=True).returncode == 0


def kill_tmux_session_if_exists(session: str) -> bool:
    if tmux("has-session", "-t", session, check=False, capture=True).returncode != 0:
        return False
    tmux("kill-session", "-t", session, check=False)
    return True


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text())


def relative_to_config(path: Path, config_path: Path) -> str:
    try:
        return str(path.relative_to(config_path.parent))
    except ValueError:
        return str(path)


def write_collected_prompts(
    config_path: Path,
    collected: list[tuple[str, str]],
    append: bool = False,
) -> list[Path]:
    if not collected:
        return []

    config_path = config_path.expanduser().resolve()
    raw = read_json(config_path)
    prompt_dir = config_path.parent / "prompts"
    prompt_dir.mkdir(parents=True, exist_ok=True)

    existing_prompts = raw.get("prompts", []) if append else []
    if not isinstance(existing_prompts, list):
        raise ValueError("prompts must be an array")

    start_index = len(existing_prompts) + 1
    new_entries: list[dict[str, str]] = []
    written_paths: list[Path] = []
    for offset, (name, text) in enumerate(collected):
        clean_name = sanitize_name(name) or f"prompt-{start_index + offset}"
        file_path = prompt_dir / f"{start_index + offset:03d}-{clean_name}.md"
        file_path.write_text(text.strip() + "\n")
        written_paths.append(file_path)
        new_entries.append(
            {
                "name": clean_name,
                "file": relative_to_config(file_path, config_path),
            }
        )

    raw["prompts"] = [*existing_prompts, *new_entries]
    if not append:
        raw["prompt_files"] = []
    config_path.write_text(json.dumps(raw, indent=2) + "\n")
    return written_paths


class Controller:
    def __init__(self, config: Config, session: str, worker_pane: str) -> None:
        self.config = config
        self.session = session
        self.worker_pane = worker_pane
        self.queue = build_run_queue(config)
        self.completed: set[int] = set()
        self.current_index: int | None = None
        self.phase = "starting"
        self.remaining_seconds: int | None = None
        self.last_ready_check_line: str | None = None
        self.last_ready_check_at: str | None = None
        self.ready_detected = False
        self.prompt_dir = config.runtime_dir / "prompts"
        self.capture_dir = config.runtime_dir / "captures"
        self.ready_check_dir = config.runtime_dir / "ready-checks"
        self.block_detected = False
        self.block_marker_line: str | None = None
        self.block_checked_at: str | None = None

    def run(self) -> None:
        if not self.queue:
            raise SystemExit("prompt-queue: no prompts configured")

        self.config.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.prompt_dir.mkdir(parents=True, exist_ok=True)
        self.capture_dir.mkdir(parents=True, exist_ok=True)
        self.ready_check_dir.mkdir(parents=True, exist_ok=True)
        write_json(self.config.runtime_dir / "controller.json", {"pid": os.getpid(), "session": self.session})
        self.render()

        for item in self.queue:
            if should_stop_after_current(self.config.runtime_dir):
                self.phase = "stopped before next prompt"
                self.current_index = None
                self.render()
                return
            if not self.run_one(item):
                return

        self.current_index = None
        self.phase = "complete"
        self.remaining_seconds = None
        self.render()

    def run_one(self, item: RunItem) -> bool:
        self.current_index = item.index
        self.phase = "launching"
        self.remaining_seconds = None
        self.render()

        self.recycle_worker()
        self.cd_worker()
        prompt_file = self.write_prompt_file(item)
        if item.prompt_delivery == "argument_file":
            self.send_shell_command(build_prompt_argument_command(item.command, prompt_file))
        elif item.prompt_delivery == "paste":
            self.send_shell_command(item.command)
        else:
            raise ValueError(f"unsupported prompt_delivery for {item.prompt_name}: {item.prompt_delivery}")

        self.sleep_with_controls(self.config.startup_wait_seconds, "startup wait")

        if item.prompt_delivery == "paste":
            self.phase = "sending prompt"
            self.render()
            self.paste_prompt(prompt_file)

        sleep_result = self.sleep_with_controls(self.config.run_seconds, "agent working", ready_item=item)
        capture_path = self.capture_run(item)
        if sleep_result == "blocked":
            self.phase = "blocked"
            self.remaining_seconds = None
            self.write_blocked_state(item, capture_path)
            self.render()
            return False
        self.stop_worker()
        self.completed.add(item.index)
        self.current_index = None
        self.phase = "captured"
        self.remaining_seconds = None
        self.render()
        return True

    def recycle_worker(self) -> None:
        if tmux_target_exists(self.worker_pane):
            tmux("respawn-pane", "-k", "-t", self.worker_pane, "-c", str(self.config.project_dir))
            self.sleep_with_controls(1, "fresh shell")

    def stop_worker(self) -> None:
        self.phase = "stopping agent"
        self.render()
        if tmux_target_exists(self.worker_pane):
            tmux("respawn-pane", "-k", "-t", self.worker_pane, "-c", str(self.config.project_dir))
            self.sleep_with_controls(1, "fresh shell")

    def cd_worker(self) -> None:
        self.phase = "cd project"
        self.render()
        self.send_shell_command(build_worker_cd_command(self.config.project_dir))
        self.sleep_with_controls(1, "cd project")

    def send_shell_command(self, command: str) -> None:
        tmux("send-keys", "-t", self.worker_pane, command, "Enter")

    def send_key(self, key: str) -> None:
        tmux("send-keys", "-t", self.worker_pane, key)

    def write_prompt_file(self, item: RunItem) -> Path:
        safe_name = sanitize_name(item.prompt_name)
        prompt_file = self.prompt_dir / f"{item.index:03d}-{safe_name}.txt"
        prompt_file.write_text(item.prompt_text)
        write_json(
            self.config.runtime_dir / "last-prompt.json",
            {
                "run_index": item.index,
                "name": item.prompt_name,
                "source": item.prompt_source,
                "path": str(prompt_file),
            },
        )
        return prompt_file

    def paste_prompt(self, prompt_file: Path) -> None:
        buffer_name = f"prompt-queue-{os.getpid()}"
        prompt_text = prompt_file.read_text().rstrip("\n")
        tmux("load-buffer", "-b", buffer_name, "-", input_text=prompt_text)
        tmux("paste-buffer", "-d", "-p", "-b", buffer_name, "-t", self.worker_pane)
        time.sleep(paste_settle_seconds(len(prompt_text)))
        self.send_key("Enter")

    def capture_run(self, item: RunItem) -> Path:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        safe_name = sanitize_name(item.prompt_name)
        output = tmux(
            "capture-pane",
            "-p",
            "-J",
            "-S",
            f"-{self.config.capture_lines}",
            "-t",
            self.worker_pane,
            capture=True,
        ).stdout
        path = self.capture_dir / f"{item.index:03d}-{safe_name}-{stamp}.txt"
        path.write_text(output)
        write_json(
            self.config.runtime_dir / "last-capture.json",
            {"run_index": item.index, "name": item.prompt_name, "path": str(path)},
        )
        return path

    def capture_worker_tail(self, lines: int) -> str:
        return tmux(
            "capture-pane",
            "-p",
            "-J",
            "-S",
            f"-{max(1, lines)}",
            "-t",
            self.worker_pane,
            capture=True,
        ).stdout

    def check_ready_marker(self, item: RunItem) -> str:
        captured = self.capture_worker_tail(self.config.ready_check_lines)
        non_empty_lines = [line for line in captured.splitlines() if line.strip()]
        last_line = non_empty_lines[-1] if non_empty_lines else ""
        matched_marker = next((marker for marker in self.config.ready_markers if marker in last_line), "")
        checked_at = datetime.now().isoformat(timespec="seconds")
        self.last_ready_check_line = last_line
        self.last_ready_check_at = checked_at
        self.ready_detected = bool(matched_marker)
        block_line = ""
        if matched_marker and self.config.block_marker:
            block_captured = self.capture_worker_tail(self.config.block_check_lines)
            block_lines = [line.strip() for line in block_captured.splitlines() if line.strip()]
            block_line = next((line for line in block_lines[-self.config.block_check_lines :] if line == self.config.block_marker), "")
            self.block_detected = bool(block_line)
            self.block_marker_line = block_line or None
            self.block_checked_at = checked_at

        safe_name = sanitize_name(item.prompt_name)
        log_path = self.ready_check_dir / f"{item.index:03d}-{safe_name}.jsonl"
        with log_path.open("a") as handle:
            handle.write(
                json.dumps(
                    {
                        "checked_at": checked_at,
                        "run_index": item.index,
                        "name": item.prompt_name,
                        "last_line": last_line,
                        "matched": bool(matched_marker),
                        "matched_marker": matched_marker,
                        "block_checked": bool(matched_marker and self.config.block_marker),
                        "block_matched": bool(block_line),
                        "block_marker": self.config.block_marker,
                    },
                    sort_keys=True,
                )
                + "\n"
            )
        if block_line:
            return "blocked"
        if matched_marker:
            return "ready"
        return "waiting"

    def write_blocked_state(self, item: RunItem, capture_path: Path) -> None:
        write_json(
            self.config.runtime_dir / "blocked.json",
            {
                "run_index": item.index,
                "name": item.prompt_name,
                "capture_path": str(capture_path),
                "marker": self.config.block_marker,
                "matched_line": self.block_marker_line,
                "checked_at": self.block_checked_at,
                "action": "queue stopped; worker pane preserved for inspection",
            },
        )

    def sleep_with_controls(self, seconds: int, phase: str, ready_item: RunItem | None = None) -> str:
        deadline = time.time() + max(0, seconds)
        ready_interval = max(0, self.config.ready_check_seconds)
        next_ready_check = time.time() + ready_interval if ready_item and ready_interval else None
        while True:
            remaining = int(round(deadline - time.time()))
            if remaining <= 0:
                self.remaining_seconds = None
                self.phase = phase
                self.render()
                return "elapsed"
            self.phase = phase
            self.remaining_seconds = remaining
            self.render()
            self.handle_keyboard()
            if consume_finish_current_sleep(self.config.runtime_dir):
                self.remaining_seconds = None
                self.phase = f"{phase} finished early"
                self.render()
                return "finish"
            if ready_item and next_ready_check is not None and time.time() >= next_ready_check:
                ready_result = self.check_ready_marker(ready_item)
                if ready_result == "blocked":
                    self.remaining_seconds = None
                    self.phase = f"{phase} blocked"
                    self.render()
                    return "blocked"
                if ready_result == "ready":
                    self.remaining_seconds = None
                    self.phase = f"{phase} ready"
                    self.render()
                    return "ready"
                next_ready_check = time.time() + ready_interval
            time.sleep(min(1, remaining))

    def handle_keyboard(self) -> None:
        while select.select([sys.stdin], [], [], 0)[0]:
            key = sys.stdin.read(1)
            if key in {"q", "Q"}:
                tmux("kill-session", "-t", self.session, check=False)
                raise SystemExit(0)
            if key in {"s", "S"}:
                (self.config.runtime_dir / STOP_NEXT_FLAG).write_text("1\n")
                self.render()
            if key in {"f", "F"}:
                (self.config.runtime_dir / FINISH_SLEEP_FLAG).write_text("1\n")
                self.render()

    def render(self) -> None:
        write_json(
            self.config.runtime_dir / "state.json",
            {
                "session": self.session,
                "worker_pane": self.worker_pane,
                "phase": self.phase,
                "current_index": self.current_index,
                "completed": sorted(self.completed),
                "stop_after_current": should_stop_after_current(self.config.runtime_dir),
                "finish_current_sleep": should_finish_current_sleep(self.config.runtime_dir),
                "remaining_seconds": self.remaining_seconds,
                "last_ready_check_at": self.last_ready_check_at,
                "last_ready_check_line": self.last_ready_check_line,
                "ready_detected": self.ready_detected,
                "block_detected": self.block_detected,
                "block_marker_line": self.block_marker_line,
                "block_checked_at": self.block_checked_at,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            },
        )
        print("\033[2J\033[H", end="")
        print(
            render_status(
                self.queue,
                self.current_index,
                self.completed,
                should_stop_after_current(self.config.runtime_dir),
                self.phase,
                self.remaining_seconds,
            ),
            flush=True,
        )


def run_controller(args: argparse.Namespace) -> None:
    runtime_dir_override = Path(args.runtime_dir) if args.runtime_dir else None
    config = load_config(
        Path(args.config),
        runtime_dir_override=runtime_dir_override,
    )
    if args.queue_file:
        config = replace(config, prompts=read_prompt_queue(Path(args.queue_file)))

    old_attrs = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        Controller(config, args.session, args.worker_pane).run()
        while True:
            select.select([sys.stdin], [], [], 1)
            Controller(config, args.session, args.worker_pane).handle_keyboard()
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)


def start_session(args: argparse.Namespace) -> None:
    if shutil.which("tmux") is None:
        raise SystemExit("prompt-queue: tmux is required")

    config_path = Path(args.config).expanduser().resolve()
    initial_config = apply_agent_override(load_config(config_path), args.cld)
    if not initial_config.prompts:
        raise SystemExit("prompt-queue: configure prompts or prompt_files in config.json")

    start_stamp = datetime.now().strftime(TIMESTAMP_FORMAT)
    config = replace(
        initial_config,
        runtime_dir=make_runtime_dir(initial_config.project_dir, start_stamp),
    )
    if not config.project_dir.is_dir():
        raise SystemExit(f"project_dir does not exist: {config.project_dir}")

    config.runtime_dir.mkdir(parents=True, exist_ok=True)
    (config.runtime_dir / STOP_NEXT_FLAG).unlink(missing_ok=True)
    (config.runtime_dir / FINISH_SLEEP_FLAG).unlink(missing_ok=True)
    queue_file = config.runtime_dir / "queue.json"
    write_prompt_queue(queue_file, config.prompts)

    session = args.session or f"{config.session_name}-{sanitize_name(config.project_dir.name)}"
    kill_tmux_session_if_exists(session)

    term_w = str(shutil.get_terminal_size((200, 50)).columns)
    term_h = str(shutil.get_terminal_size((200, 50)).lines)
    script = Path(__file__).resolve()

    controller_id = tmux(
        "new-session",
        "-d",
        "-s",
        session,
        "-n",
        "queue",
        "-c",
        str(config.project_dir),
        "-x",
        term_w,
        "-y",
        term_h,
        "-P",
        "-F",
        "#{pane_id}",
        "bash",
        capture=True,
    ).stdout.strip()
    worker_id = tmux(
        "split-window",
        "-t",
        controller_id,
        "-v",
        "-c",
        str(config.project_dir),
        "-P",
        "-F",
        "#{pane_id}",
        "bash",
        capture=True,
    ).stdout.strip()

    tmux("set-option", "-t", session, "history-limit", str(config.history_limit))
    tmux("set-option", "-t", session, "mouse", "on")
    tmux("set-option", "-t", session, "status", "on")
    tmux("set-option", "-t", session, "status-position", "top")
    tmux("set-option", "-t", session, "status-left", f"#[fg=cyan,bold] prompt-queue {config.project_dir.name} ")
    tmux("set-option", "-t", session, "status-right", "")

    controller_cmd = (
        f"python3 {sh_quote(str(script))} "
        f"--config {sh_quote(str(config_path))} "
        f"__controller "
        f"--session {sh_quote(session)} "
        f"--worker-pane {sh_quote(worker_id)} "
        f"--runtime-dir {sh_quote(str(config.runtime_dir))} "
        f"--queue-file {sh_quote(str(queue_file))}"
    )
    tmux("send-keys", "-t", controller_id, controller_cmd, "Enter")
    tmux("select-pane", "-t", controller_id)

    write_json(
        config.runtime_dir / "session.json",
        {
            "session": session,
            "worker_pane": worker_id,
            "project_dir": str(config.project_dir),
            "runtime_dir": str(config.runtime_dir),
            "queue_file": str(queue_file),
            "started_at": start_stamp,
            "prompt_count": len(config.prompts),
            "command": config.command,
            "prompt_delivery": config.prompt_delivery,
        },
    )
    if not args.no_attach:
        attach_session(session)


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def attach_session(session: str) -> None:
    if os.environ.get("TMUX"):
        os.execvp("tmux", ["tmux", "switch-client", "-t", session])
    os.execvp("tmux", ["tmux", "attach-session", "-t", session])


def read_session(runtime_dir: Path) -> str:
    session_file = runtime_dir / "session.json"
    if not session_file.exists():
        raise SystemExit(f"no session metadata at {session_file}")
    return str(json.loads(session_file.read_text())["session"])


def load_config_for_control(args: argparse.Namespace) -> Config:
    return load_config(Path(args.config))


def stop_next(args: argparse.Namespace) -> None:
    config = load_config_for_control(args)
    runtime_dir = latest_runtime_dir(config.project_dir)
    (runtime_dir / STOP_NEXT_FLAG).write_text("1\n")
    print(f"armed stop-after-current: {runtime_dir / STOP_NEXT_FLAG}")


def finish_sleep(args: argparse.Namespace) -> None:
    config = load_config_for_control(args)
    runtime_dir = latest_runtime_dir(config.project_dir)
    (runtime_dir / FINISH_SLEEP_FLAG).write_text("1\n")
    print(f"armed finish-current-sleep: {runtime_dir / FINISH_SLEEP_FLAG}")


def kill(args: argparse.Namespace) -> None:
    config = load_config_for_control(args)
    runtime_dir = latest_runtime_dir(config.project_dir)
    session = args.session or read_session(runtime_dir)
    tmux("kill-session", "-t", session, check=False)
    print(f"killed tmux session: {session}")


def status(args: argparse.Namespace) -> None:
    config = load_config_for_control(args)
    runtime_dir = latest_runtime_dir(config.project_dir)
    state_file = runtime_dir / "state.json"
    if not state_file.exists():
        raise SystemExit(f"no state file at {state_file}")
    print(state_file.read_text(), end="")


def collect_prompts(args: argparse.Namespace) -> None:
    config_path = Path(args.config).expanduser().resolve()
    collected: list[tuple[str, str]] = []

    print(f"Writing prompts into {config_path.parent / 'prompts'}")
    print(f"Paste each prompt, then finish it with a line containing only {args.end_marker!r}.")
    print(f"When asked for the next prompt, type {NO_MORE_PROMPTS!r} to finish.")

    index = 1
    while True:
        name = f"prompt-{index}"
        print(f"\nprompt {index}: paste text; end with {args.end_marker!r} on its own line.")
        print(f"or type {NO_MORE_PROMPTS!r} on its own line to finish:")
        lines: list[str] = []
        while True:
            try:
                line = input()
            except EOFError:
                line = args.end_marker
            if not lines and line.strip().lower() == NO_MORE_PROMPTS:
                lines = []
                break
            if line == args.end_marker:
                break
            lines.append(line)

        text = "\n".join(lines).strip()
        if not lines and not text:
            break
        if text:
            collected.append((name, text))
            index += 1
        else:
            print("empty prompt skipped")

    written_paths = write_collected_prompts(config_path, collected, append=args.append)
    if not written_paths:
        print("no prompts collected; config unchanged")
        return

    action = "appended" if args.append else "wrote"
    print(f"{action} {len(written_paths)} prompt file(s) and updated {config_path}")
    for path in written_paths:
        print(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="prompt-queue")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to config.json")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="start or attach to the tmux prompt queue session")
    run.add_argument("--session", default="", help="override tmux session name")
    run.add_argument("--no-attach", action="store_true", help="create session without attaching")
    run.add_argument("--cld", action="store_true", help="run Claude via cld and paste prompts instead of Codex")
    run.set_defaults(func=start_session)

    controller = sub.add_parser("__controller")
    controller.add_argument("--session", required=True)
    controller.add_argument("--worker-pane", required=True)
    controller.add_argument("--runtime-dir", default="")
    controller.add_argument("--queue-file", default="")
    controller.set_defaults(func=run_controller)

    attach = sub.add_parser("attach", help="attach to the last session")
    attach.set_defaults(func=lambda args: attach_session(read_session(latest_runtime_dir(load_config_for_control(args).project_dir))))

    stop = sub.add_parser("stop-next", help="finish current prompt, then stop")
    stop.set_defaults(func=stop_next)

    finish = sub.add_parser("finish-sleep", help="finish the current controller sleep immediately")
    finish.set_defaults(func=finish_sleep)

    kill_cmd = sub.add_parser("kill", help="kill the tmux session now")
    kill_cmd.add_argument("--session", default="", help="override tmux session name")
    kill_cmd.set_defaults(func=kill)

    stat = sub.add_parser("status", help="print JSON controller state")
    stat.set_defaults(func=status)

    collect = sub.add_parser("collect-prompts", help="paste prompts into files and update config.json")
    collect.add_argument("--append", action="store_true", help="append to existing config prompts instead of replacing them")
    collect.add_argument("--end-marker", default=DEFAULT_PROMPT_END_MARKER, help="line that ends one pasted prompt")
    collect.set_defaults(func=collect_prompts)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
