#!/usr/bin/env python3
"""doctor 子命令：合并旧 verify/status/doctor/check 四个 action 的诊断面。

- 核心 verify（core.verify）
- claude CLI 存在性 / --version / claude doctor / auth status
- plugin 注册检查（plugins.registered vs plugins.toml claude-plugin 全部命中）
- --smoke-test：script/check-claude-doctor.sh 子进程 + claude -p /context Skills 段冒烟
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if __package__ in (None, ""):  # 直接执行本文件时补 sys.path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from launch import core, manifest, plugins, util

SKILLS_SECTION_MIN_ROWS = 2  # /context 的 Skills 段应至少含表头 + 一行数据


def _repo_root() -> Path:
    return util.repo_root()


def _claude_home() -> Path:
    from launch.agents import resolve_agent
    return resolve_agent("claude").skills_dir.parent


def _frontmatter_name(skill_md: Path) -> str:
    """SKILL.md frontmatter name: 字段，取不到回退目录名。"""
    try:
        for line in skill_md.read_text(encoding="utf-8", errors="replace").splitlines()[:40]:
            m = re.match(r"^name:\s*(.+?)\s*$", line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return skill_md.parent.name


def _installed_skill_names() -> list[str]:
    """~/.claude/skills/ 下的全部 skill 名（目录 + SKILL.md）。"""
    skills_dir = _claude_home() / "skills"
    if not skills_dir.is_dir():
        return []
    names = []
    for entry in sorted(skills_dir.iterdir()):
        skill_md = entry / "SKILL.md"
        if entry.is_dir() and skill_md.is_file():
            names.append(_frontmatter_name(skill_md))
    return names


def check_claude_cli() -> int:
    """claude 存在性 → 版本 → claude doctor → auth status。"""
    failed = 0
    claude_bin = shutil.which("claude")
    util.phase("claude CLI 存在性")
    if not claude_bin:
        util.err("claude 命令未找到 (PATH 中无 claude)")
        return 1
    real = Path(claude_bin).resolve()
    util.log(f"claude 可执行文件: {real}")
    version = subprocess.run(["claude", "--version"], capture_output=True, text=True)
    ver_line = (version.stdout or version.stderr).strip().splitlines()
    util.log(f"Claude Code 已安装: {ver_line[0] if ver_line else '?'}")

    util.phase("claude doctor 健康检查")
    if util.DRY_RUN:
        util.dry("claude doctor")
    else:
        proc = subprocess.run(["claude", "doctor"], capture_output=True, text=True)
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode == 0 and "No installation issues found." in out:
            util.log("claude doctor: 无安装问题")
        else:
            util.err(f"claude doctor 失败 (exit {proc.returncode}):")
            for line in out.splitlines()[:20]:
                print(f"    {line}", file=sys.stderr)
            failed = 1

    util.phase("claude auth 认证状态")
    if util.DRY_RUN:
        util.dry("claude auth status --json")
    else:
        auth = subprocess.run(["claude", "auth", "status", "--json"],
                              capture_output=True, text=True)
        out = (auth.stdout or "") + (auth.stderr or "")
        if '"loggedIn": true' in out:
            method = "unknown"
            try:
                method = json.loads(auth.stdout or "{}").get("authMethod") or "unknown"
            except ValueError:
                pass
            util.log(f"claude 已登录 (authMethod={method})")
        else:
            util.warn("claude 未登录 — 安装可用但需认证才能使用")
    return failed


def check_registered_plugins() -> int:
    """plugins.toml 里全部 claude-plugin 条目须在 claude plugin list 中命中。"""
    root = _repo_root()
    entries = [p for p in manifest.load_plugins(root / "configs" / "plugins.toml")
               if p.method == "claude-plugin"]
    if not entries:
        util.info("无 claude-plugin 清单条目，跳过注册检查")
        return 0
    if util.DRY_RUN:
        util.dry("claude plugin list --json")
        return 0
    util.info("运行 claude plugin list 注册检查...")
    registered = plugins.registered()
    failed = 0
    for entry in entries:
        plugin_id = f"{entry.name}@{entry.marketplace}"
        if registered.get(plugin_id):
            util.log(f"plugin '{plugin_id}' 已注册")
        else:
            util.err(f"plugin '{plugin_id}' 未注册或 scope 不是 user")
            failed = 1
    return failed


def check_claude_doctor_script() -> int:
    """script/check-claude-doctor.sh 子进程（OMC 插件诊断），超时默认 15s。"""
    root = _repo_root()
    script = root / "script" / "check-claude-doctor.sh"
    if util.DRY_RUN:
        util.dry(str(script))
        return 0
    timeout_seconds = int(os.environ.get("CLAUDE_DOCTOR_TIMEOUT", "15"))
    util.info("运行最终 Claude doctor...")
    try:
        proc = subprocess.run(["bash", str(script)], timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        util.err(f"Claude doctor 超时 ({timeout_seconds}s)")
        return 1
    if proc.returncode != 0:
        util.err(f"Claude doctor 失败 ({proc.returncode})")
        return 1
    util.log("Claude doctor 通过")
    return 0


def check_context_smoke() -> int:
    """claude -p /context 的 Skills 段非空，且 skills.toml 每个 name 在输出中命中。"""
    if not shutil.which("claude"):
        util.err("Claude -p /context 检查失败: claude 命令不存在")
        return 1
    root = _repo_root()
    expected = [s.name for s in manifest.load_skills(root / "configs" / "skills.toml")]

    if util.DRY_RUN:
        util.dry("claude -p /context")
        return 0

    timeout_seconds = int(os.environ.get("CLAUDE_CONTEXT_TIMEOUT", "15"))
    try:
        proc = subprocess.run(["claude", "-p", "/context"],
                              capture_output=True, text=True, timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        util.err(f"Claude -p /context 检查超时 ({timeout_seconds}s)")
        return 1
    if proc.returncode != 0:
        util.err(f"Claude -p /context 检查失败 ({proc.returncode})")
        for line in ((proc.stdout or "") + (proc.stderr or "")).splitlines()[:40]:
            print(line, file=sys.stderr)
        return proc.returncode
    context = proc.stdout or ""
    if not context.strip():
        util.err("Claude -p /context 未输出上下文信息")
        return 1

    # Skills 段：### Skills 到下一个 ### 之间的表格行；<2 行 = 未注入。
    m = re.search(r"(?ms)^### Skills$(.*?)(?=^### |\Z)", context)
    rows = [l for l in (m.group(1) if m else "").splitlines() if l.startswith("| ")]
    if len(rows) < SKILLS_SECTION_MIN_ROWS:
        util.err("Claude -p /context 的 Skills 段为空，skill 未被加载")
        for line in ((m.group(1) if m else "")).splitlines()[:40]:
            print(line, file=sys.stderr)
        return 1

    # skills.toml 声明的每个 skill 名须出现在 /context 输出中。
    failed = 0
    installed = _installed_skill_names()
    for name in expected:
        if name in installed and f"| {name} " in context:
            util.log(f"skill '{name}' 已安装且在 Claude /context 中可见")
        elif name in installed:
            util.err(f"skill '{name}' 未出现在 Claude -p /context 的 Skills 表")
            failed = 1
        # 未安装的清单项（用户选择不装）不阻断冒烟。
    if failed:
        util.err("Claude -p /context 逐项 skill 检查失败")
    else:
        util.log("Claude -p /context 上下文注入检查通过")
    return failed


def run(*, smoke: bool, no_verify: bool) -> int:
    """doctor 主入口。返回 0 通过 / 1 有失败项。"""
    if no_verify:
        util.info("跳过 doctor (--no-verify)")
        return 0

    from launch.agents import resolve_agent
    agent = resolve_agent("claude")

    util.phase("Phase 1: 核心配置验证")
    rc = core.verify(agent)

    util.phase("Phase 2: claude CLI 检查")
    if check_claude_cli():
        rc = 1

    util.phase("Phase 3: plugin 注册检查")
    if check_registered_plugins():
        rc = 1

    if smoke:
        util.phase("Phase 4: OMC doctor (check-claude-doctor.sh)")
        if check_claude_doctor_script():
            rc = 1
        util.phase("Phase 5: claude -p /context 冒烟")
        if check_context_smoke():
            rc = 1

    if rc == 0:
        util.log("doctor 检查全部通过")
    else:
        util.err("doctor 检查存在失败项")
    return rc


if __name__ == "__main__":
    # 自检：--no-verify 直接通过；dry-run 全路径无副作用（无 claude 环境也只打印）。
    from launch import util as _u

    _u.VERBOSE = True
    assert run(smoke=False, no_verify=True) == 0
    _u.DRY_RUN = True
    assert run(smoke=False, no_verify=False) in (0, 1)
    print("doctor self-check ok")
