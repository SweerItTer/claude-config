#!/usr/bin/env python3
"""Calculate the next available Requirement or Spec stable ID."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from governance_config import ConfigError, load_config


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument("--config", help="Explicit repository-relative governance JSON file")
    parser.add_argument("--prefix", choices=("R", "S"), required=True)
    parser.add_argument("--width", type=int, default=None, help="Minimum zero-padding width")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.exists() or not repo.is_dir():
        parser.error(f"Repository path is not a directory: {repo}")
    try:
        config = load_config(repo, args.config)
    except ConfigError as exc:
        parser.error(str(exc))

    pattern = re.compile(rf"^{args.prefix}(\d+)(?:$|[-_. ])")
    values: list[int] = []
    observed_widths: list[int] = []
    roots = [config.requirement_dir if args.prefix == "R" else config.specs_dir, config.archive_dir]
    seen: set[Path] = set()
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path in seen:
                continue
            seen.add(path)
            match = pattern.match(path.stem)
            if match:
                digits = match.group(1)
                values.append(int(digits))
                observed_widths.append(len(digits))

    next_value = max(values, default=0) + 1
    width = args.width if args.width is not None else max([2, *observed_widths])
    width = max(width, len(str(next_value)))
    print(f"{args.prefix}{next_value:0{width}d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
