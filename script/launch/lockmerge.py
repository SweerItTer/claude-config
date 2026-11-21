#!/usr/bin/env python3
"""把并行安装 worker 各自的 skill lock 合并回规范 lock。

吸收自 script/merge-skill-locks.py，CLI 改为函数：merge_locks(target, worker_locks)。

npx skills 的全局 lock 是"读-改-写"且没有文件锁，多个 `add` 并行写同一 lock 必然
互相覆盖丢条目（实测 4 个并行装完只剩 3 条）。丢条目的 skill 会被下次最新版比对判成
"未安装"而反复重装。因此并行 worker 各用独立 XDG_STATE_HOME 写各自的 lock，结束后由
本模块合并：以规范 lock 为基准，只覆盖本次装到的 skill 条目，其余既有条目原样保留；
顶层字段只在规范 lock 缺失时从 worker 补（不覆盖既有值）。
"""

from __future__ import annotations

import json
import os
from pathlib import Path


def _read_lock(path: Path) -> dict | None:
    try:
        with open(path, encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def merge_locks(target: Path, worker_locks: list[Path]) -> None:
    """合并 worker locks 到 target。失败抛 OSError/ValueError（调用方决定如何汇报）。

    语义照搬：worker 按顺序覆盖；既有条目与顶层字段绝不丢。
    """
    target = Path(target)
    workers = [Path(p) for p in worker_locks]
    base = _read_lock(target)
    if base is None:
        version = 3
        for worker in workers:
            data = _read_lock(worker)
            if data and isinstance(data.get("version"), int):
                version = data["version"]
                break
        base = {"version": version, "skills": {}}
    if not isinstance(base.get("skills"), dict):
        base["skills"] = {}

    for worker in workers:
        data = _read_lock(worker)
        if not data:
            continue
        for name, entry in (data.get("skills") or {}).items():
            base["skills"][name] = entry
        # 规范 lock 缺的顶层字段才补（如 lastSelectedAgents），绝不覆盖既有值
        for key, value in data.items():
            if key != "skills" and key not in base:
                base[key] = value

    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.parent / (target.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fp:
        json.dump(base, fp, indent=2)
        fp.write("\n")
    os.replace(tmp, target)


if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        target = root / "lock.json"
        worker_a = root / "a.json"
        worker_b = root / "b.json"
        worker_a.write_text(json.dumps({
            "version": 3, "lastSelectedAgents": ["universal"],
            "skills": {"alpha": {"source": "org-a/repo-a", "skillFolderHash": "h1"}},
        }), encoding="utf-8")
        worker_b.write_text(json.dumps({
            "version": 3,
            "skills": {"beta": {"source": "org-b/repo-b", "skillFolderHash": "h2"}},
        }), encoding="utf-8")

        # 规范 lock 不存在：从 worker 补 version，全部条目并入
        merge_locks(target, [worker_a, worker_b])
        merged = json.loads(target.read_text(encoding="utf-8"))
        assert set(merged["skills"]) == {"alpha", "beta"}, merged
        assert merged["lastSelectedAgents"] == ["universal"]

        # 既有条目与顶层字段不被覆盖；只覆盖本次装到的条目
        target.write_text(json.dumps({
            "version": 3, "lastSelectedAgents": ["claude"],
            "skills": {
                "unrelated": {"source": "someone/else", "skillFolderHash": "keep-me"},
                "alpha": {"source": "org-a/repo-a", "skillFolderHash": "old"},
            },
        }), encoding="utf-8")
        worker_c = root / "c.json"
        worker_c.write_text(json.dumps({
            "version": 3, "lastSelectedAgents": ["universal"],
            "skills": {"alpha": {"source": "org-a/repo-a", "skillFolderHash": "new"}},
        }), encoding="utf-8")
        merge_locks(target, [worker_c])
        merged = json.loads(target.read_text(encoding="utf-8"))
        assert merged["skills"]["unrelated"]["skillFolderHash"] == "keep-me"
        assert merged["skills"]["alpha"]["skillFolderHash"] == "new"
        assert merged["lastSelectedAgents"] == ["claude"]  # 不覆盖既有顶层字段

        # worker lock 损坏/缺失：跳过不炸
        merge_locks(target, [root / "missing.json", worker_c])

    print("lockmerge self-check passed.")
