from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
from typing import BinaryIO

try:  # Python 3.11+
    import tomllib as _tomllib
except ModuleNotFoundError:  # Python 3.10
    _tomllib = None


@dataclass(slots=True, frozen=True)
class Limits:
    sessions: int = 6
    windows_per_session: int = 8
    panes_per_window: int = 4


@dataclass(slots=True, frozen=True)
class Config:
    limits: Limits = Limits()


_LIMIT_KEYS = {"sessions", "windows_per_session", "panes_per_window"}
_SECTION_RE = re.compile(r"^\[([A-Za-z0-9_.-]+)\]$")
_ASSIGN_RE = re.compile(r"^([A-Za-z0-9_.-]+)\s*=\s*([+]?[0-9]+)\s*(?:#.*)?$")


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
        raw = _load_toml(fp)
    limits_raw = raw.get("limits", {})
    limits = Limits(
        sessions=_positive_int(limits_raw.get("sessions", 6), "limits.sessions"),
        windows_per_session=_positive_int(limits_raw.get("windows_per_session", 8), "limits.windows_per_session"),
        panes_per_window=_positive_int(limits_raw.get("panes_per_window", 4), "limits.panes_per_window"),
    )
    return Config(limits=limits)


def _load_toml(fp: BinaryIO) -> dict[str, object]:
    if _tomllib is not None:
        return _tomllib.load(fp)
    return _load_toml_310(fp.read())


def _load_toml_310(data: bytes) -> dict[str, object]:
    """Strict Python-3.10 fallback for the tool's intentionally tiny config schema.

    v0.x only consumes positive integer keys under [limits]. Rejecting unsupported
    TOML is safer than silently interpreting it differently from tomllib.
    """
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("config must be UTF-8") from exc

    result: dict[str, object] = {}
    current: str | None = None
    for lineno, original in enumerate(text.splitlines(), 1):
        line = original.strip()
        if not line or line.startswith("#"):
            continue
        section = _SECTION_RE.fullmatch(line)
        if section:
            current = section.group(1)
            if current != "limits":
                raise ValueError(f"unsupported config section [{current}] at line {lineno}")
            result.setdefault("limits", {})
            continue
        if current != "limits":
            raise ValueError(f"config key outside [limits] at line {lineno}")
        match = _ASSIGN_RE.fullmatch(line)
        if not match:
            raise ValueError(f"unsupported config syntax at line {lineno}")
        key, raw_value = match.groups()
        if key not in _LIMIT_KEYS:
            raise ValueError(f"unsupported limits key {key!r} at line {lineno}")
        limits = result.setdefault("limits", {})
        assert isinstance(limits, dict)
        limits[key] = int(raw_value, 10)
    return result


def _positive_int(value: object, key: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError(f"{key} must be a positive integer")
    return value
