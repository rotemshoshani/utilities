from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .config import AppConfig


class IntervalKind(str, Enum):
    WORK = "work"
    REST = "rest"


@dataclass(frozen=True, slots=True)
class Interval:
    kind: IntervalKind
    seconds: int
    cut_number: int
    total_cuts: int


class PomodoroTimer:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        self.current_cut = 1
        self.interval = self._make_work_interval()
        self.remaining_seconds = self.interval.seconds
        self.paused = False
        self.completed_work_cuts = 0

    def tick(self, seconds: int = 1) -> bool:
        if self.paused:
            return False
        self.remaining_seconds = max(0, self.remaining_seconds - seconds)
        return self.remaining_seconds == 0

    def advance(self) -> Interval:
        completed = self.interval
        if self.interval.kind == IntervalKind.WORK:
            self.completed_work_cuts += 1
            if self.current_cut < self.config.work_cuts:
                self.current_cut += 1
                self.interval = self._make_work_interval()
            else:
                self.interval = self._make_rest_interval()
        else:
            self.current_cut = 1
            self.interval = self._make_work_interval()
        self.remaining_seconds = self.interval.seconds
        return completed

    def reset_cycle(self) -> None:
        self.current_cut = 1
        self.interval = self._make_work_interval()
        self.remaining_seconds = self.interval.seconds
        self.paused = False

    def replace_config(self, config: AppConfig) -> None:
        self.config = config
        self.reset_cycle()

    def toggle_pause(self) -> None:
        self.paused = not self.paused

    def _make_work_interval(self) -> Interval:
        return Interval(
            IntervalKind.WORK,
            max(1, round(self.config.work_minutes * 60)),
            self.current_cut,
            self.config.work_cuts,
        )

    def _make_rest_interval(self) -> Interval:
        return Interval(
            IntervalKind.REST,
            max(1, round(self.config.rest_minutes * 60)),
            self.config.work_cuts,
            self.config.work_cuts,
        )


def format_seconds(seconds: int) -> str:
    minutes, secs = divmod(max(0, seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"
