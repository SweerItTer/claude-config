from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import tomllib


@dataclass(slots=True, frozen=True)
class Limits:
    sessions: int = 6
    windows_per_session: int = 8
    panes_per_window: int = 4


@dataclass(slots=True, frozen=True)
class Config:
    limits: Limits = Limits()


def load_config(path: str | None) -> Config:
    if path is None:
        candidate = Path.cwd() / ".tmux-tool.toml"
        if not candidate.exists():
            return Config()
        path_obj = candidate
    else:
        path_obj = Path(path)
        if not path_obj.exists():
            raise ValueError(f"config not found: {path_obj}")

    with path_obj.open("rb") as fp:
        raw = tomllib.load(fp)
    limits_raw = raw.get("limits", {})
    limits = Limits(
        sessions=_positive_int(limits_raw.get("sessions", 6), "limits.sessions"),
        windows_per_session=_positive_int(limits_raw.get("windows_per_session", 8), "limits.windows_per_session"),
        panes_per_window=_positive_int(limits_raw.get("panes_per_window", 4), "limits.panes_per_window"),
    )
    return Config(limits=limits)


def _positive_int(value: object, key: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError(f"{key} must be a positive integer")
    return value
