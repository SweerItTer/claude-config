#!/usr/bin/env python3
"""Parse skills.toml / plugins.toml into tab-separated rows for setup.sh.

Replaces the previous awk-based pseudo-parsers in setup.sh, which silently
dropped values containing "=" (e.g. `command = "npx -y skills@latest ... = ..."`)
and could not validate structure.

Usage:
    parse-manifests.py skills --file configs/skills.toml
    parse-manifests.py plugins --file configs/plugins.toml

Output (tab-separated, one record per line; empty fields blank):
    skills:  name  repo  skill  agent  scope  note
    plugins: name  repo  method  marketplace  command  note

Exits non-zero on schema violations (missing required field, unknown method).
"""

import argparse
import sys
from pathlib import Path

try:
    import tomllib  # Python 3.11+

    HAS_TOMLLIB = True
except ModuleNotFoundError:  # Python 3.10 及更早
    HAS_TOMLLIB = False

SKILL_KEYS = ("name", "repo", "skill", "agent", "scope", "note")
PLUGIN_KEYS = ("name", "repo", "method", "marketplace", "command", "note")
PLUGIN_METHODS = {"claude-plugin", "npx"}
SKILL_REQUIRED = ("name", "repo")
PLUGIN_REQUIRED = ("name", "repo", "method")

DEFAULTS = {
    "skill": "*",
    "agent": "claude-code",
    "scope": "global",
    "method": "claude-plugin",
}


def _row(item, keys):
    """Flatten one manifest item into a tab-separated string."""
    values = []
    for key in keys:
        value = item.get(key)
        if value is None:
            value = DEFAULTS.get(key, "")
        if not isinstance(value, str):
            return None, f"{key} 字段必须是字符串，收到 {type(value).__name__}"
        values.append(value)
    return "\t".join(values), None


def _parse_subset_toml(text):
    """Zero-dependency TOML-subset parser for the manifest files.

    Supports only what skills.toml / plugins.toml use: arrays of tables
    (``[[sources]]`` / ``[[plugins]]``) with plain string key/value pairs,
    plus ``#`` comments and blank lines. Raises ValueError on anything else.

    Intended as a fallback for Python 3.10, where the standard library has
    no TOML parser and we refuse to add a runtime dependency.
    """
    entries = []
    current = None
    table_name = None

    def push():
        nonlocal current
        if current is not None:
            entries.append(current)
        current = {}

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[[") and line.endswith("]]"):
            table = line[2:-2].strip()
            if table not in ("sources", "plugins"):
                raise ValueError(f"第 {lineno} 行: 不支持的顶层表 [[{table}]]")
            if table_name is not None and table != table_name:
                raise ValueError(f"第 {lineno} 行: 清单同时包含 [[sources]] 和 [[plugins]]，不支持")
            table_name = table
            push()
            continue
        if "=" not in line:
            raise ValueError(f"第 {lineno} 行: 无法解析的键值对: {line!r}")
        key, _, raw_value = line.partition("=")
        key = key.strip()
        value = raw_value.strip()
        if not (value.startswith('"') and value.endswith('"')):
            raise ValueError(f"第 {lineno} 行: 值必须是双引号字符串: {line!r}")
        if current is None:
            raise ValueError(f"第 {lineno} 行: 键 {key!r} 出现在任何 [[表]] 之外")
        current[key] = value[1:-1]

    push()
    if table_name is None:
        raise ValueError("清单中没有 [[sources]] 或 [[plugins]] 表")
    return {table_name: entries}


def load(manifest_path):
    path = Path(manifest_path)
    if not path.is_file():
        print(f"[ERR] 清单文件不存在: {manifest_path}", file=sys.stderr)
        raise SystemExit(1)
    text = path.read_text(encoding="utf-8")
    try:
        if HAS_TOMLLIB:
            return tomllib.loads(text)
        return _parse_subset_toml(text)
    except ValueError as exc:  # TOMLDecodeError 是 ValueError 子类
        print(f"[ERR] 清单解析失败 ({path}): {exc}", file=sys.stderr)
        raise SystemExit(1)


def parse_skills(path):
    data = load(path)
    entries = data.get("sources", [])
    if not isinstance(entries, list):
        print("[ERR] skills.toml 顶层 sources 必须是数组", file=sys.stderr)
        raise SystemExit(1)

    errors = []
    rows = []
    for index, item in enumerate(entries, start=1):
        if not isinstance(item, dict):
            errors.append(f"[{index}] source 必须是对象")
            continue
        missing = [key for key in SKILL_REQUIRED if key not in item]
        if missing:
            errors.append(f"[{index}] 缺少必填字段: {', '.join(missing)}")
            continue
        row, err = _row(item, SKILL_KEYS)
        if err:
            errors.append(f"[{index}] {err}")
        else:
            rows.append(row)

    if errors:
        print("[ERR] skills.toml 校验失败:", file=sys.stderr)
        for message in errors:
            print(f"  {message}", file=sys.stderr)
        raise SystemExit(1)
    return rows


def parse_plugins(path):
    data = load(path)
    entries = data.get("plugins", [])
    if not isinstance(entries, list):
        print("[ERR] plugins.toml 顶层 plugins 必须是数组", file=sys.stderr)
        raise SystemExit(1)

    errors = []
    rows = []
    for index, item in enumerate(entries, start=1):
        if not isinstance(item, dict):
            errors.append(f"[{index}] plugin 必须是对象")
            continue
        missing = [key for key in PLUGIN_REQUIRED if key not in item]
        if missing:
            errors.append(f"[{index}] 缺少必填字段: {', '.join(missing)}")
            continue
        method = item.get("method", "claude-plugin")
        if method not in PLUGIN_METHODS:
            errors.append(f"[{index}] method 必须是 {'|'.join(sorted(PLUGIN_METHODS))}，收到: {method}")
            continue
        row, err = _row(item, PLUGIN_KEYS)
        if err:
            errors.append(f"[{index}] {err}")
        else:
            rows.append(row)

    if errors:
        print("[ERR] plugins.toml 校验失败:", file=sys.stderr)
        for message in errors:
            print(f"  {message}", file=sys.stderr)
        raise SystemExit(1)
    return rows


def main(argv):
    parser = argparse.ArgumentParser(description="解析 skills.toml / plugins.toml")
    sub = parser.add_subparsers(dest="command", required=True)
    for name, help_text in (("skills", "解析 skills.toml"), ("plugins", "解析 plugins.toml")):
        sub_parser = sub.add_parser(name, help=help_text)
        sub_parser.add_argument("--file", required=True, help="TOML 清单路径")

    args = parser.parse_args(argv)
    if args.command == "skills":
        rows = parse_skills(args.file)
    else:
        rows = parse_plugins(args.file)
    print("\n".join(rows))


if __name__ == "__main__":
    main(sys.argv[1:])
