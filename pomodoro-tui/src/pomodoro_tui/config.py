from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re


APP_DIR_NAME = "pomodoro-tui"
CONFIG_FILE_NAME = "config.json"


@dataclass(slots=True)
class AppConfig:
    work_minutes: float = 25.0
    work_cuts: int = 1
    rest_minutes: float = 5.0
    point_mode: str = "chunk"

    @classmethod
    def from_values(
        cls,
        work: str,
        rest_minutes: float,
        point_mode: str = "chunk",
    ) -> "AppConfig":
        work_minutes, work_cuts = parse_work_spec(work)
        if rest_minutes <= 0:
            raise ValueError("Rest minutes must be greater than zero.")
        if point_mode not in {"chunk", "minutes"}:
            raise ValueError("Point mode must be 'chunk' or 'minutes'.")
        return cls(work_minutes, work_cuts, float(rest_minutes), point_mode)


def parse_work_spec(value: str) -> tuple[float, int]:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)(?:\s*x\s*(\d+))?\s*", value)
    if not match:
        raise ValueError("Work must look like '25' or '10x5'.")
    minutes = float(match.group(1))
    cuts = int(match.group(2) or "1")
    if minutes <= 0:
        raise ValueError("Work minutes must be greater than zero.")
    if cuts <= 0:
        raise ValueError("Work cut count must be greater than zero.")
    return minutes, cuts


def data_dir() -> Path:
    root = os.environ.get("XDG_DATA_HOME")
    if root:
        return Path(root) / APP_DIR_NAME
    return Path.home() / ".local" / "share" / APP_DIR_NAME


def config_path() -> Path:
    return data_dir() / CONFIG_FILE_NAME


def load_config(path: Path | None = None) -> AppConfig:
    path = path or config_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return AppConfig()
    except json.JSONDecodeError:
        return AppConfig()

    try:
        return AppConfig(
            work_minutes=float(raw.get("work_minutes", 25.0)),
            work_cuts=int(raw.get("work_cuts", 1)),
            rest_minutes=float(raw.get("rest_minutes", 5.0)),
            point_mode=str(raw.get("point_mode", "chunk")),
        )
    except (TypeError, ValueError):
        return AppConfig()


def save_config(config: AppConfig, path: Path | None = None) -> None:
    path = path or config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(config), indent=2) + "\n", encoding="utf-8")
