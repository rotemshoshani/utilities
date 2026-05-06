from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
import json
import os
from pathlib import Path
from typing import Any

from .config import APP_DIR_NAME


STATS_FILE_NAME = "stats.json"


def stats_path() -> Path:
    root = os.environ.get("XDG_DATA_HOME")
    if root:
        return Path(root) / APP_DIR_NAME / STATS_FILE_NAME
    return Path.home() / ".local" / "share" / APP_DIR_NAME / STATS_FILE_NAME


@dataclass(frozen=True, slots=True)
class WorkEvent:
    completed_at: datetime
    work_minutes: float
    points: float

    def to_json(self) -> dict[str, Any]:
        return {
            "completed_at": self.completed_at.isoformat(timespec="seconds"),
            "work_minutes": self.work_minutes,
            "points": self.points,
        }

    @classmethod
    def from_json(cls, raw: dict[str, Any]) -> "WorkEvent":
        return cls(
            completed_at=datetime.fromisoformat(str(raw["completed_at"])),
            work_minutes=float(raw["work_minutes"]),
            points=float(raw["points"]),
        )


class StatsStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or stats_path()
        self.events = self._load()

    def record_work_cut(self, work_minutes: float, point_mode: str) -> WorkEvent:
        points = 1.0 if point_mode == "chunk" else float(work_minutes)
        event = WorkEvent(datetime.now().astimezone(), float(work_minutes), points)
        self.events.append(event)
        self.save()
        return event

    def totals(self) -> dict[str, float]:
        return {
            "points": sum(event.points for event in self.events),
            "work_minutes": sum(event.work_minutes for event in self.events),
            "cuts": float(len(self.events)),
        }

    def today_points(self, today: date | None = None) -> float:
        today = today or date.today()
        return sum(event.points for event in self.events if event.completed_at.date() == today)

    def daily_streak(self, today: date | None = None) -> int:
        return _consecutive_dates(self._active_dates(), today or date.today())

    def weekly_streak(self, today: date | None = None) -> int:
        today = today or date.today()
        active_weeks = {event.completed_at.date().isocalendar()[:2] for event in self.events}
        current = today.isocalendar()[:2]
        streak = 0
        cursor = _monday_of_iso_week(*current)
        while cursor.isocalendar()[:2] in active_weeks:
            streak += 1
            cursor -= timedelta(days=7)
        return streak

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"events": [event.to_json() for event in self.events]}
        self.path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    def _load(self) -> list[WorkEvent]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return []
        except json.JSONDecodeError:
            return []
        events = []
        for item in raw.get("events", []):
            try:
                events.append(WorkEvent.from_json(item))
            except (KeyError, TypeError, ValueError):
                continue
        return events

    def _active_dates(self) -> set[date]:
        return {event.completed_at.date() for event in self.events}


def _consecutive_dates(active_dates: set[date], today: date) -> int:
    streak = 0
    cursor = today
    while cursor in active_dates:
        streak += 1
        cursor -= timedelta(days=1)
    return streak


def _monday_of_iso_week(year: int, week: int) -> date:
    return date.fromisocalendar(year, week, 1)
