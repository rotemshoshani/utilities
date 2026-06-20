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
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


DEFAULT_CONFIG = Path(__file__).with_name("config.json")
STOP_NEXT_FLAG = "stop-next.flag"
TIMESTAMP_FORMAT = "%Y%m%d-%H%M%S"


@dataclass(frozen=True)
class Agent:
    name: str
    command: str
    startup_keys: tuple[str, ...] = ()
    submit_keys: tuple[str, ...] = ("Enter",)
    prompt_delivery: str = "paste"


@dataclass(frozen=True)
class Config:
    project_dir: Path
    runtime_dir: Path
    num_runs: int
    run_seconds: int
    startup_wait_seconds: int
    post_startup_wait_seconds: int
    capture_lines: int
    history_limit: int
    session_name: str
    prompt: str
    agents: tuple[Agent, ...]


@dataclass(frozen=True)
class RunItem:
    index: int
    cycle: int
    agent_name: str
    command: str
    startup_keys: tuple[str, ...] = ()
    submit_keys: tuple[str, ...] = ("Enter",)
    prompt_delivery: str = "paste"


def expand_path(value: str, base_dir: Path) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if not path.is_absolute():
        path = base_dir / path
    return path


def expand_project_path(value: str) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if not path.is_absolute():
        path = Path.cwd() / path
    return path.resolve()


def load_config(
    path: Path = DEFAULT_CONFIG,
    project_dir_override: Path | None = None,
    runtime_dir_override: Path | None = None,
) -> Config:
    path = path.expanduser().resolve()
    base_dir = path.parent
    raw = json.loads(path.read_text())

    agents = tuple(
        Agent(
            name=str(item["name"]),
            command=str(item["command"]),
            startup_keys=tuple(str(key) for key in item.get("startup_keys", [])),
            submit_keys=tuple(str(key) for key in item.get("submit_keys", ["Enter"])),
            prompt_delivery=str(item.get("prompt_delivery", "paste")),
        )
        for item in raw.get("agents", [])
    )
    if not agents:
        raise ValueError("config must define at least one agent in agents")

    num_runs = int(raw.get("num_runs", 1))
    if num_runs < 1:
        raise ValueError("num_runs must be at least 1")

    project_dir = (
        project_dir_override.expanduser().resolve()
        if project_dir_override is not None
        else expand_project_path(str(raw.get("project_dir", ".")))
    )
    runtime_dir = runtime_dir_override if runtime_dir_override is not None else make_runtime_dir(project_dir)

    return Config(
        project_dir=project_dir,
        runtime_dir=runtime_dir,
        num_runs=num_runs,
        run_seconds=int(raw.get("run_seconds", 3600)),
        startup_wait_seconds=int(raw.get("startup_wait_seconds", 10)),
        post_startup_wait_seconds=int(raw.get("post_startup_wait_seconds", 3)),
        capture_lines=int(raw.get("capture_lines", 400)),
        history_limit=int(raw.get("history_limit", 200000)),
        session_name=str(raw.get("session_name", "sec-advisor")),
        prompt=str(raw.get("prompt", "")),
        agents=agents,
    )


def build_run_queue(config: Config) -> list[RunItem]:
    queue: list[RunItem] = []
    index = 1
    for cycle in range(1, config.num_runs + 1):
        for agent in config.agents:
            queue.append(
                RunItem(
                    index=index,
                    cycle=cycle,
                    agent_name=agent.name,
                    command=agent.command,
                    startup_keys=agent.startup_keys,
                    submit_keys=agent.submit_keys,
                    prompt_delivery=agent.prompt_delivery,
                )
            )
            index += 1
    return queue


def default_work_base_dir(project_dir: Path) -> Path:
    return project_dir / ".planning" / "work" / "sec-advisor"


def make_runtime_dir(project_dir: Path, timestamp: str | None = None) -> Path:
    stamp = timestamp or datetime.now().strftime(TIMESTAMP_FORMAT)
    return default_work_base_dir(project_dir) / stamp


def latest_runtime_dir(project_dir: Path) -> Path:
    base_dir = default_work_base_dir(project_dir)
    candidates = sorted(path for path in base_dir.iterdir() if path.is_dir()) if base_dir.exists() else []
    candidates = [path for path in candidates if (path / "session.json").exists() or (path / "state.json").exists()]
    if not candidates:
        raise SystemExit(f"no sec-advisor runs found under {base_dir}")
    return candidates[-1]


def build_worker_cd_command(project_dir: Path) -> str:
    return f"cd -- {sh_quote(str(project_dir))}"


def should_stop_after_current(runtime_dir: Path) -> bool:
    return (runtime_dir / STOP_NEXT_FLAG).exists()


def render_status(
    queue: list[RunItem],
    current_index: int | None,
    completed: set[int],
    stop_after_current: bool,
    phase: str = "idle",
    remaining_seconds: int | None = None,
) -> str:
    lines = ["sec-advisor", ""]
    for item in queue:
        if item.index in completed:
            marker = "V"
        elif current_index == item.index:
            marker = "in progress"
        else:
            marker = "queued"
        lines.append(f"{item.agent_name} #{item.index} ... {marker}")

    lines.extend(["", f"phase: {phase}"])
    if remaining_seconds is not None:
        lines.append(f"sleep remaining: {format_duration(remaining_seconds)}")
    lines.append(f"[S] stop after current: {'armed' if stop_after_current else 'off'}")
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


def tmux(*args: str, check: bool = True, capture: bool = False, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["tmux", *args],
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=check,
    )


def tmux_target_exists(target: str) -> bool:
    return tmux("display-message", "-p", "-t", target, "#{pane_id}", check=False, capture=True).returncode == 0


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def render_prompt(template: str, config: Config, item: RunItem) -> str:
    return template.format(
        agent_name=item.agent_name,
        run_index=item.index,
        cycle=item.cycle,
        project_dir=str(config.project_dir),
        runtime_dir=str(config.runtime_dir),
        audit_dir=str(config.runtime_dir),
    )


def build_prompt_argument_command(command: str, prompt_file: Path) -> str:
    return f"{command} \"$(cat {sh_quote(str(prompt_file))})\""


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
        self.capture_dir = config.runtime_dir / "captures"

    def run(self) -> None:
        self.config.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.capture_dir.mkdir(parents=True, exist_ok=True)
        write_json(self.config.runtime_dir / "controller.json", {"pid": os.getpid(), "session": self.session})
        self.render()

        for item in self.queue:
            if should_stop_after_current(self.config.runtime_dir):
                self.phase = "stopped before next run"
                self.current_index = None
                self.render()
                return
            self.run_one(item)

        self.current_index = None
        self.phase = "complete"
        self.remaining_seconds = None
        self.render()

    def run_one(self, item: RunItem) -> None:
        self.current_index = item.index
        self.phase = "launching"
        self.remaining_seconds = None
        self.render()

        self.recycle_worker()
        self.cd_worker()
        prompt = render_prompt(self.config.prompt, self.config, item)
        if item.prompt_delivery == "argument_file":
            prompt_file = self.write_prompt_file(prompt)
            self.send_shell_command(build_prompt_argument_command(item.command, prompt_file))
        else:
            self.send_shell_command(item.command)
        self.sleep_with_controls(self.config.startup_wait_seconds, "startup wait")

        for key in item.startup_keys:
            self.send_key(key)
            self.sleep_with_controls(1, f"startup key {key}")
        if item.startup_keys:
            self.sleep_with_controls(self.config.post_startup_wait_seconds, "post startup wait")

        if item.prompt_delivery == "paste":
            self.phase = "sending prompt"
            self.render()
            self.paste_prompt(prompt)
            for key in item.submit_keys:
                self.send_key(key)
        elif item.prompt_delivery != "argument_file":
            raise ValueError(f"unsupported prompt_delivery for {item.agent_name}: {item.prompt_delivery}")

        self.sleep_with_controls(self.config.run_seconds, "agent working")
        self.capture_run(item)
        self.completed.add(item.index)
        self.current_index = None
        self.phase = "captured"
        self.remaining_seconds = None
        self.render()

    def recycle_worker(self) -> None:
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

    def write_prompt_file(self, prompt: str) -> Path:
        prompt_file = self.config.runtime_dir / "last-prompt.txt"
        prompt_file.write_text(prompt)
        return prompt_file

    def paste_prompt(self, prompt: str) -> None:
        prompt_file = self.write_prompt_file(prompt)
        buffer_name = f"sec-advisor-{os.getpid()}"
        tmux("load-buffer", "-b", buffer_name, str(prompt_file))
        tmux("paste-buffer", "-d", "-b", buffer_name, "-t", self.worker_pane)

    def capture_run(self, item: RunItem) -> None:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        safe_agent = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in item.agent_name)
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
        path = self.capture_dir / f"{item.index:03d}-{safe_agent}-{stamp}.txt"
        path.write_text(output)
        write_json(
            self.config.runtime_dir / "last-capture.json",
            {"run_index": item.index, "agent": item.agent_name, "path": str(path)},
        )

    def sleep_with_controls(self, seconds: int, phase: str) -> None:
        deadline = time.time() + max(0, seconds)
        while True:
            remaining = int(round(deadline - time.time()))
            if remaining <= 0:
                self.remaining_seconds = None
                self.phase = phase
                self.render()
                return
            self.phase = phase
            self.remaining_seconds = remaining
            self.render()
            self.handle_keyboard()
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
    project_dir_override = Path(args.project_dir) if args.project_dir else None
    runtime_dir_override = Path(args.runtime_dir) if args.runtime_dir else None
    config = load_config(
        Path(args.config),
        project_dir_override=project_dir_override,
        runtime_dir_override=runtime_dir_override,
    )
    old_attrs = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        Controller(config, args.session, args.worker_pane).run()
        while True:
            select.select([sys.stdin], [], [], 1)
            Controller(config, args.session, args.worker_pane).handle_keyboard()
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)


def sanitize_session_part(value: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in value).strip("-")
    return cleaned or "project"


def start_session(args: argparse.Namespace) -> None:
    if shutil.which("tmux") is None:
        raise SystemExit("sec-advisor: tmux is required")

    config_path = Path(args.config).expanduser().resolve()
    project_dir_override = Path(args.project_dir) if args.project_dir else None
    initial_config = load_config(config_path, project_dir_override=project_dir_override)
    start_stamp = datetime.now().strftime(TIMESTAMP_FORMAT)
    config = load_config(
        config_path,
        project_dir_override=project_dir_override,
        runtime_dir_override=make_runtime_dir(initial_config.project_dir, start_stamp),
    )
    if not config.project_dir.is_dir():
        raise SystemExit(f"project_dir does not exist: {config.project_dir}")

    config.runtime_dir.mkdir(parents=True, exist_ok=True)
    (config.runtime_dir / STOP_NEXT_FLAG).unlink(missing_ok=True)

    session = args.session or f"{config.session_name}-{sanitize_session_part(config.project_dir.name)}"
    if tmux("has-session", "-t", session, check=False, capture=True).returncode == 0:
        attach_session(session)
        return

    term_w = str(shutil.get_terminal_size((200, 50)).columns)
    term_h = str(shutil.get_terminal_size((200, 50)).lines)
    script = Path(__file__).resolve()

    controller_id = tmux(
        "new-session",
        "-d",
        "-s",
        session,
        "-n",
        "audit",
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
    tmux("set-option", "-t", session, "status-left", f"#[fg=cyan,bold] sec-advisor {config.project_dir.name} ")
    tmux("set-option", "-t", session, "status-right", "")

    controller_cmd = (
        f"python3 {sh_quote(str(script))} "
        f"--config {sh_quote(str(config_path))} "
        f"__controller "
        f"--session {sh_quote(session)} "
        f"--worker-pane {sh_quote(worker_id)} "
        f"--runtime-dir {sh_quote(str(config.runtime_dir))}"
    )
    if args.project_dir:
        controller_cmd += f" --project-dir {sh_quote(str(config.project_dir))}"
    tmux("send-keys", "-t", controller_id, controller_cmd, "Enter")
    tmux("select-pane", "-t", controller_id)

    write_json(
        config.runtime_dir / "session.json",
        {
            "session": session,
            "worker_pane": worker_id,
            "project_dir": str(config.project_dir),
            "runtime_dir": str(config.runtime_dir),
            "started_at": start_stamp,
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
    project_dir_override = Path(args.project_dir) if getattr(args, "project_dir", "") else None
    return load_config(Path(args.config), project_dir_override=project_dir_override)


def stop_next(args: argparse.Namespace) -> None:
    config = load_config_for_control(args)
    runtime_dir = latest_runtime_dir(config.project_dir)
    (runtime_dir / STOP_NEXT_FLAG).write_text("1\n")
    print(f"armed stop-after-current: {runtime_dir / STOP_NEXT_FLAG}")


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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="sec-advisor")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to config.json")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="start or attach to the tmux audit session")
    run.add_argument("project_dir", nargs="?", default="", help="repo path to audit; overrides config.json project_dir")
    run.add_argument("--session", default="", help="override tmux session name")
    run.add_argument("--no-attach", action="store_true", help="create session without attaching")
    run.set_defaults(func=start_session)

    controller = sub.add_parser("__controller")
    controller.add_argument("--session", required=True)
    controller.add_argument("--worker-pane", required=True)
    controller.add_argument("--project-dir", default="")
    controller.add_argument("--runtime-dir", default="")
    controller.set_defaults(func=run_controller)

    attach = sub.add_parser("attach", help="attach to the last session")
    attach.add_argument("project_dir", nargs="?", default="", help="repo path; overrides config.json project_dir")
    attach.set_defaults(func=lambda args: attach_session(read_session(latest_runtime_dir(load_config_for_control(args).project_dir))))

    stop = sub.add_parser("stop-next", help="finish current run, then stop")
    stop.add_argument("project_dir", nargs="?", default="", help="repo path; overrides config.json project_dir")
    stop.set_defaults(func=stop_next)

    kill_cmd = sub.add_parser("kill", help="kill the tmux session now")
    kill_cmd.add_argument("project_dir", nargs="?", default="", help="repo path; overrides config.json project_dir")
    kill_cmd.add_argument("--session", default="", help="override tmux session name")
    kill_cmd.set_defaults(func=kill)

    stat = sub.add_parser("status", help="print JSON controller state")
    stat.add_argument("project_dir", nargs="?", default="", help="repo path; overrides config.json project_dir")
    stat.set_defaults(func=status)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
