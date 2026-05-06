from __future__ import annotations

import argparse

from .config import AppConfig, load_config
from .tui import run_tui


def main(argv: list[str] | None = None) -> int:
    saved = load_config()
    parser = argparse.ArgumentParser(
        prog="pomodoro-tui",
        description="Run a Pomodoro++ terminal timer with configurable work cuts and rests.",
    )
    parser.add_argument(
        "--work",
        default=None,
        help="Work cut duration, optionally with count. Examples: 25, 10x5.",
    )
    parser.add_argument(
        "--rest",
        type=float,
        default=None,
        help="Rest duration in minutes after all work cuts complete.",
    )
    parser.add_argument(
        "--point-mode",
        choices=("chunk", "minutes"),
        default=None,
        help="Award 1 point per work cut, or points equal to completed work minutes.",
    )
    args = parser.parse_args(argv)

    config = AppConfig.from_values(
        work=args.work if args.work is not None else f"{saved.work_minutes:g}x{saved.work_cuts}",
        rest_minutes=args.rest if args.rest is not None else saved.rest_minutes,
        point_mode=args.point_mode if args.point_mode is not None else saved.point_mode,
    )
    return run_tui(config)
