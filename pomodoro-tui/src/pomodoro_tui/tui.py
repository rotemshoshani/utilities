from __future__ import annotations

import curses
import time

from .config import AppConfig, save_config
from .stats import StatsStore
from .timer import IntervalKind, PomodoroTimer, format_seconds


def run_tui(config: AppConfig) -> int:
    try:
        return curses.wrapper(_run, config)
    except KeyboardInterrupt:
        return 130


def _run(stdscr: curses.window, config: AppConfig) -> int:
    curses.curs_set(0)
    stdscr.nodelay(True)
    stdscr.timeout(100)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_CYAN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_RED, -1)

    stats = StatsStore()
    timer = PomodoroTimer(config)
    message = "Ready"
    last_tick = time.monotonic()

    while True:
        now = time.monotonic()
        if now - last_tick >= 1:
            elapsed = int(now - last_tick)
            last_tick += elapsed
            if timer.tick(elapsed):
                completed = timer.advance()
                if completed.kind == IntervalKind.WORK:
                    event = stats.record_work_cut(config.work_minutes, config.point_mode)
                    message = f"+{event.points:g} point for cut {completed.cut_number}/{completed.total_cuts}"
                else:
                    message = "Rest complete"

        _draw(stdscr, timer, stats, message)
        key = stdscr.getch()
        if key == -1:
            continue
        if key in (ord("q"), ord("Q")):
            return 0
        if key == ord(" "):
            timer.toggle_pause()
            message = "Paused" if timer.paused else "Running"
        elif key in (ord("n"), ord("N")):
            completed = timer.advance()
            message = f"Skipped {completed.kind.value}"
            last_tick = time.monotonic()
        elif key in (ord("r"), ord("R")):
            timer.reset_cycle()
            message = "Cycle reset"
            last_tick = time.monotonic()
        elif key in (ord("w"), ord("W")):
            config = _edit_float(stdscr, config, "Work cut minutes", "work_minutes")
            timer.replace_config(config)
            message = "Work minutes updated"
            last_tick = time.monotonic()
        elif key in (ord("c"), ord("C")):
            config = _edit_int(stdscr, config, "Cuts per cycle", "work_cuts")
            timer.replace_config(config)
            message = "Cut count updated"
            last_tick = time.monotonic()
        elif key in (ord("b"), ord("B")):
            config = _edit_float(stdscr, config, "Rest minutes", "rest_minutes")
            timer.replace_config(config)
            message = "Rest minutes updated"
            last_tick = time.monotonic()
        elif key in (ord("p"), ord("P")):
            config.point_mode = "minutes" if config.point_mode == "chunk" else "chunk"
            timer.replace_config(config)
            message = f"Point mode: {config.point_mode}"
            last_tick = time.monotonic()
        elif key in (ord("s"), ord("S")):
            save_config(config)
            message = "Defaults saved"


def _draw(stdscr: curses.window, timer: PomodoroTimer, stats: StatsStore, message: str) -> None:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    totals = stats.totals()
    kind = "WORK" if timer.interval.kind == IntervalKind.WORK else "REST"
    color = curses.color_pair(1 if timer.interval.kind == IntervalKind.WORK else 2)
    paused = "PAUSED" if timer.paused else "RUNNING"
    title = "Pomodoro++"

    _add_center(stdscr, 1, title, curses.A_BOLD)
    _add_center(stdscr, 3, kind, color | curses.A_BOLD)
    _add_center(stdscr, 5, format_seconds(timer.remaining_seconds), curses.A_BOLD)
    _add_center(
        stdscr,
        7,
        f"Cut {timer.current_cut}/{timer.config.work_cuts} | Work {timer.config.work_minutes:g}m | Rest {timer.config.rest_minutes:g}m",
        curses.A_NORMAL,
    )
    _add_center(stdscr, 9, paused, curses.color_pair(3) if timer.paused else curses.A_DIM)

    left = max(0, (width - 54) // 2)
    rows = [
        f"Today: {stats.today_points():g} pts",
        f"Total: {totals['points']:g} pts | {totals['cuts']:g} cuts | {totals['work_minutes']:g} min",
        f"Daily streak: {stats.daily_streak()} | Weekly streak: {stats.weekly_streak()}",
        f"Point mode: {timer.config.point_mode}",
    ]
    for idx, row in enumerate(rows, start=12):
        _add_str(stdscr, idx, left, row[: max(0, width - left - 1)])

    controls = "Space pause  n skip  r reset  w work  c cuts  b rest  p points  s save  q quit"
    _add_center(stdscr, max(0, height - 3), controls[: max(0, width - 1)], curses.A_DIM)
    _add_center(stdscr, max(0, height - 2), message[: max(0, width - 1)], curses.color_pair(4))
    stdscr.refresh()


def _edit_float(stdscr: curses.window, config: AppConfig, label: str, field: str) -> AppConfig:
    value = _prompt(stdscr, f"{label}: ")
    try:
        parsed = float(value)
        if parsed > 0:
            setattr(config, field, parsed)
    except ValueError:
        pass
    return config


def _edit_int(stdscr: curses.window, config: AppConfig, label: str, field: str) -> AppConfig:
    value = _prompt(stdscr, f"{label}: ")
    try:
        parsed = int(value)
        if parsed > 0:
            setattr(config, field, parsed)
    except ValueError:
        pass
    return config


def _prompt(stdscr: curses.window, prompt: str) -> str:
    curses.echo()
    stdscr.nodelay(False)
    height, width = stdscr.getmaxyx()
    y = max(0, height - 1)
    stdscr.move(y, 0)
    stdscr.clrtoeol()
    _add_str(stdscr, y, 0, prompt[: max(0, width - 1)])
    stdscr.refresh()
    try:
        raw = stdscr.getstr(y, min(len(prompt), max(0, width - 1)), 20)
        return raw.decode("utf-8").strip()
    finally:
        curses.noecho()
        stdscr.nodelay(True)


def _add_center(stdscr: curses.window, y: int, text: str, attr: int = curses.A_NORMAL) -> None:
    _, width = stdscr.getmaxyx()
    x = max(0, (width - len(text)) // 2)
    _add_str(stdscr, y, x, text, attr)


def _add_str(
    stdscr: curses.window,
    y: int,
    x: int,
    text: str,
    attr: int = curses.A_NORMAL,
) -> None:
    height, width = stdscr.getmaxyx()
    if y < 0 or y >= height or x >= width:
        return
    stdscr.addstr(y, max(0, x), text[: max(0, width - max(0, x) - 1)], attr)
