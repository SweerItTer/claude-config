#!/usr/bin/env python3
"""update 子命令实现：仓库自更新 + 全量外部资源更新。

旧版 update_repository 更新后会 re-exec setup.sh 重载 bash 代码；Python 版
不需要（模块随进程加载，git pull 后的下一次进程启动自然使用新代码）。
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ""):  # 直接执行本文件时补 sys.path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from launch import plugins, skills, util
from launch.agents import AgentSpec


def _repo_root() -> Path:
    return util.repo_root()


def update_repo() -> int:
    """git pull --ff-only --depth=1；失败 err。dry-run 只打印。"""
    root = _repo_root()
    if util.DRY_RUN:
        util.dry(f"git -C {root} pull --ff-only --depth=1")
        return 0
    util.info("更新当前仓库...")
    proc = subprocess.run(["git", "-C", str(root), "pull", "--ff-only", "--depth=1"])
    if proc.returncode != 0:
        util.err("仓库更新失败 (git pull --ff-only)")
        return 1
    util.log("仓库已更新")
    return 0


def update_all(agent: AgentSpec) -> int:
    """全部外部 skills 更新；claude 目标追加全部第三方 plugins。"""
    rc = 0
    if skills.update([], agent):
        rc = 1
    if agent.plugins and plugins.update([]):
        rc = 1
    return rc


if __name__ == "__main__":
    # 自检：dry-run 全路径无副作用 + agents 目标不触碰 plugins
    from launch import util as _u

    _u.DRY_RUN = True
    assert update_repo() == 0
    agents_spec = __import__("launch.agents", fromlist=["resolve_agent"]).resolve_agent("agents")
    assert update_all(agents_spec) == 0
    print("updater self-check ok")
