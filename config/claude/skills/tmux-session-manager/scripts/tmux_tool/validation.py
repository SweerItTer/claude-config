from __future__ import annotations

import argparse
import math
import re


ROLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")


def positive_int(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return value


def positive_finite_float(raw: str) -> float:
    try:
        value = float(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be a finite number > 0")
    return value


def tcp_port(raw: str) -> int:
    value = positive_int(raw)
    if value > 65535:
        raise argparse.ArgumentTypeError("must be in 1..65535")
    return value


def validate_role(role: str | None) -> bool:
    return role is None or ROLE_RE.fullmatch(role) is not None


def contains_control(value: str) -> bool:
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in value)


def validate_metadata_text(value: str, *, allow_tab: bool = False) -> bool:
    for ch in value:
        code = ord(ch)
        if code == 0 or code == 127:
            return False
        if code < 32 and not (allow_tab and ch == "\t"):
            return False
    return True
