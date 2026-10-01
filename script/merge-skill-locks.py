#!/usr/bin/env python3
"""把并行安装 worker 各自的 skill lock 合并回规范 lock。

npx skills 的全局 lock 是"读-改-写"且没有文件锁，多个 `add` 并行写同一 lock 必然
互相覆盖丢条目（实测 4 个并行装完只剩 3 条）。丢条目的 skill 会被下次最新版比对判成
"未安装"而反复重装。因此并行 worker 各用独立 XDG_STATE_HOME 写各自的 lock，结束后由
本脚本合并：以规范 lock 为基准，只覆盖本次装到的 skill 条目，其余既有条目原样保留；
顶层字段只在规范 lock 缺失时从 worker 补（不覆盖既有值）。

用法：merge-skill-locks.py --target <规范 lock> <worker lock>...
输出：写入的 skill 条目数（stdout），便于调用方汇报。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def read_lock(path: Path) -> dict | None:
    try:
        with open(path, encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def merge(target_path: Path, worker_paths: list[str]) -> int:
    target = read_lock(target_path)
    if target is None:
        version = 3
        for worker in worker_paths:
            data = read_lock(Path(worker))
            if data and isinstance(data.get("version"), int):
                version = data["version"]
                break
        target = {"version": version, "skills": {}}
    if not isinstance(target.get("skills"), dict):
        target["skills"] = {}

    written: set[str] = set()
    for worker in worker_paths:
        data = read_lock(Path(worker))
        if not data:
            continue
        for name, entry in (data.get("skills") or {}).items():
            target["skills"][name] = entry
            written.add(name)
        # 规范 lock 缺的顶层字段才补（如 lastSelectedAgents），绝不覆盖既有值
        for key, value in data.items():
            if key != "skills" and key not in target:
                target[key] = value

    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = target_path.parent / (target_path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fp:
        json.dump(target, fp, indent=2)
        fp.write("\n")
    os.replace(tmp, target_path)
    return len(written)


def main() -> int:
    parser = argparse.ArgumentParser(description="合并并行安装产生的 skill lock")
    parser.add_argument("--target", required=True, help="规范 lock 路径（合并目标）")
    parser.add_argument("workers", nargs="*", help="worker lock 路径（按顺序覆盖）")
    args = parser.parse_args()

    try:
        written = merge(Path(args.target), args.workers)
    except OSError as exc:
        print(f"合并 lock 失败: {exc}", file=sys.stderr)
        return 1
    print(written)
    return 0


if __name__ == "__main__":
    sys.exit(main())
