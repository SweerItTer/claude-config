"""agent 目标解析：claude（~/.claude/skills）与 agents（~/.agents/skills，universal 共享目录）。

自检: cd script && python3 -m launch.agents
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

if __package__ in (None, ""):  # 允许 python3 script/launch/agents.py 直接跑自检
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from launch.util import err


@dataclass(frozen=True)
class AgentSpec:
    key: str          # "claude" | "agents"
    npx_key: str      # npx skills 的 -a 值："claude-code" | "universal"
    skills_dir: Path  # skills 安装目录
    core: bool        # 仅 claude 目标同步核心配置
    plugins: bool     # 仅 claude 目标支持 claude plugin


def resolve_agent(name: str) -> AgentSpec:
    """claude/claude-code → claude 完整目标；agents → universal 仅 skills 目标。

    CLAUDE_CONFIG_DIR / AGENTS_SKILLS_HOME 环境变量覆盖默认目录（沙箱测试依赖）。
    """
    normalized = (name or "").strip().lower()
    if normalized in ("claude", "claude-code"):
        base = os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"
        return AgentSpec("claude", "claude-code",
                         Path(base).expanduser() / "skills", True, True)
    if normalized == "agents":
        # AGENTS_SKILLS_HOME 直接就是 skills 目录（不是家目录）
        base = os.environ.get("AGENTS_SKILLS_HOME") or "~/.agents/skills"
        return AgentSpec("agents", "universal", Path(base).expanduser(), False, False)
    err(f"未知 agent 目标: {name} (有效值: claude, claude-code, agents)")
    raise SystemExit(2)


def _lock_file() -> Path:
    override = os.environ.get("SKILLS_LOCK_FILE")
    if override:
        return Path(override).expanduser()
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return Path(xdg).expanduser() / "skills" / ".skill-lock.json"
    return Path.home() / ".agents" / ".skill-lock.json"


# npx skills 全局 lock（记录每个 skill 的安装来源与 skillFolderHash），最新版比对的数据源。
LOCK_FILE: Path = _lock_file()


if __name__ == "__main__":
    from tempfile import TemporaryDirectory

    from launch.util import log

    with TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        os.environ["CLAUDE_CONFIG_DIR"] = str(tmp_path / "claude-home")
        os.environ["AGENTS_SKILLS_HOME"] = str(tmp_path / "agents-home" / "skills")

        claude = resolve_agent("claude")
        assert claude.key == "claude" and claude.npx_key == "claude-code"
        assert claude.skills_dir == tmp_path / "claude-home" / "skills"
        assert claude.core and claude.plugins
        assert resolve_agent("claude-code").key == "claude"
        assert resolve_agent("Claude").key == "claude"  # 大小写不敏感

        agents = resolve_agent("agents")
        assert agents.key == "agents" and agents.npx_key == "universal"
        assert agents.skills_dir == tmp_path / "agents-home" / "skills"
        assert not agents.core and not agents.plugins

        del os.environ["CLAUDE_CONFIG_DIR"]
        assert resolve_agent("claude").skills_dir == Path.home() / ".claude" / "skills"

        # LOCK_FILE 解析优先级：SKILLS_LOCK_FILE > XDG_STATE_HOME > ~/.agents
        os.environ["SKILLS_LOCK_FILE"] = str(tmp_path / "lock.json")
        assert _lock_file() == tmp_path / "lock.json"
        del os.environ["SKILLS_LOCK_FILE"]
        os.environ["XDG_STATE_HOME"] = str(tmp_path / "state")
        assert _lock_file() == tmp_path / "state" / "skills" / ".skill-lock.json"
        del os.environ["XDG_STATE_HOME"]
        assert _lock_file() == Path.home() / ".agents" / ".skill-lock.json"

        try:
            resolve_agent("codex")
            raise AssertionError("codex 应被拒绝")
        except SystemExit as exc:
            assert exc.code == 2

    log("launch.agents 自检通过")
