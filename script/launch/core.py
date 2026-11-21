"""launch.core — claude 核心配置同步/验证/卸载（B 切片）。

迁移来源：
- setup.sh: ensure_managed_block / ensure_user_local_bin_path / ensure_core_config /
  ensure_settings_json / render_settings_template / merge_settings_json /
  verify_core_config / verify_repository_cleanliness / remove_managed_block /
  uninstall_core / remove_legacy_ecc_paths
- script/install-common.sh: remove_legacy_settings_entries /
  remove_legacy_marketplace_entries / remove_legacy_installed_plugins_entries /
  remove_legacy_rtk_link

agent 参数为 agents.AgentSpec 形状的鸭子类型（key/skills_dir/core 属性）；
不 import agents 以避免循环依赖。claude home 取 agent.skills_dir.parent
（agents.resolve_agent 已尊重 CLAUDE_CONFIG_DIR）。
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if __package__ in (None, ""):
    # 直接执行（python3 script/launch/core.py）时把 script/ 与 script/launch/ 加入 sys.path
    _here = Path(__file__).resolve()
    sys.path.insert(0, str(_here.parents[1]))
    sys.path.insert(0, str(_here.parent))

try:
    from launch import util
except ImportError:  # A 切片未就绪 / 直接文件执行时按同目录模块解析
    import util  # type: ignore[no-redef]


# --- 链接与块的小工具（verify 用；与 bash symlink_points_to/file_has_block/is_valid_claude_md 同义） ---

def _symlink_points_to(link: Path, target: Path) -> bool:
    if not link.is_symlink() or not target.exists():
        return False
    return os.path.realpath(link) == os.path.realpath(target)


def _file_has_block(path: Path, block_name: str) -> bool:
    if not path.is_file():
        return False
    pattern = rf"<!--\s*{block_name}:START\s*-->"
    return re.search(pattern, path.read_text(encoding="utf-8", errors="replace")) is not None


def _is_valid_claude_md(claude_md: Path, ccfg_src: Path) -> bool:
    if _symlink_points_to(claude_md, ccfg_src):
        return True
    return (
        claude_md.is_file()
        and not claude_md.is_symlink()
        and _file_has_block(claude_md, "Claude-Config")
        and _file_has_block(claude_md, "OMC")
    )


# --- managed block（setup.sh ensure_managed_block 内嵌 python 的直接函数化） ---

def _merge_managed_block(src: Path, dst: Path, block_name: str,
                         start_marker: str, end_marker: str,
                         hash_prefix: str, hash_suffix: str) -> None:
    start_re = re.escape(start_marker)
    end_re = re.escape(end_marker)
    # 旧安装可能在 shell RC 里留下 HTML 风格 marker，一并匹配以便迁移到 # 格式。
    legacy_start_re = rf"<!--\s*{re.escape(block_name)}:START\s*-->"
    legacy_end_re = rf"<!--\s*{re.escape(block_name)}:END\s*-->"
    hash_re = rf"(?:<!--\s*hash:|#\s*hash:)([0-9a-f]+)\s*(?:-->)?"

    raw_source = src.read_text(encoding="utf-8").strip()
    inner_pattern = re.compile(
        rf"(?ms)^\s*(?:{start_re}|{legacy_start_re})\s*\n(.*?)\n(?:{end_re}|{legacy_end_re})\s*$"
    )
    match = inner_pattern.match(raw_source)
    inner = match.group(1).strip() if match else raw_source
    inner = re.sub(rf"^{hash_re}\s*\n", "", inner, count=1).strip()
    digest = hashlib.sha256(inner.encode("utf-8")).hexdigest()[:16]
    hash_line = f"{hash_prefix}{digest}{hash_suffix}"
    source = f"{start_marker}\n{hash_line}\n{inner}\n{end_marker}"

    existing = dst.read_text(encoding="utf-8") if dst.exists() else ""
    block_pattern = re.compile(
        rf"(?ms)^\s*(?:{start_re}|{legacy_start_re})\s*\n(.*?)\n(?:{end_re}|{legacy_end_re})[ \t]*\n?"
    )
    block_match = block_pattern.search(existing)
    if block_match:
        current_hash = re.search(hash_re, block_match.group(1))
        block_is_legacy = bool(re.search(legacy_start_re, block_match.group(0)))
        if current_hash and current_hash.group(1) == digest and not block_is_legacy:
            return
        merged = block_pattern.sub(source + "\n", existing, count=1).strip() + "\n"
    elif existing.strip():
        merged = existing.rstrip() + "\n\n" + source + "\n"
    else:
        merged = source + "\n"

    dst.write_text(merged, encoding="utf-8")


def ensure_managed_block(src: Path, dst: Path, block_name: str, label: str) -> None:
    """把 src 的受管块合并进 dst；幂等（hash 相同且非 legacy 格式则不写）。"""
    # shell RC 用 # 注释；.md 文件用 <!-- -->。
    is_md = dst.suffix == ".md"
    start_marker = f"<!-- {block_name}:START -->" if is_md else f"# {block_name}:START"
    end_marker = f"<!-- {block_name}:END -->" if is_md else f"# {block_name}:END"
    hash_prefix = "<!-- hash:" if is_md else "# hash:"
    hash_suffix = " -->" if is_md else ""

    if not src.is_file():
        return
    if util.DRY_RUN:
        util.dry(f"merge {src} into {dst} as {block_name} block")
        return

    dst.parent.mkdir(parents=True, exist_ok=True)
    if _symlink_points_to(dst, src):
        dst.unlink()

    _merge_managed_block(src, dst, block_name, start_marker, end_marker, hash_prefix, hash_suffix)
    util.log(f"{label} 已合并")


# --- PATH RC 注入（setup.sh ensure_user_local_bin_path） ---

_LOCAL_BIN_SNIPPET = (
    "case \":$PATH:\" in\n"
    "  *\":$HOME/.local/bin:\"*) ;;\n"
    "  *) export PATH=\"$HOME/.local/bin:$PATH\" ;;\n"
    "esac\n"
)


def ensure_user_local_bin_path() -> None:
    home = Path.home()
    # 当前会话也补上（后续 npx 安装可能需要 ~/.local/bin）
    if f":{home}/.local/bin:" not in f":{os.environ.get('PATH', '')}:":
        os.environ["PATH"] = f"{home}/.local/bin:{os.environ.get('PATH', '')}"

    targets = [home / ".profile"]
    shell_name = os.path.basename(os.environ.get("SHELL", ""))
    bashrc = home / ".bashrc"
    zshrc = home / ".zshrc"
    if shell_name == "bash" or bashrc.is_file():
        targets.append(bashrc)
    if shell_name == "zsh" or zshrc.is_file():
        targets.append(zshrc)

    # 去重目标（SHELL 与已存在文件可能指向同一个 RC）
    seen = set()
    unique_targets = []
    for target in targets:
        if target in seen:
            continue
        seen.add(target)
        unique_targets.append(target)

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".sh", delete=False) as tmp:
            tmp.write(_LOCAL_BIN_SNIPPET)
            tmp_path = Path(tmp.name)
        for target in unique_targets:
            ensure_managed_block(tmp_path, target, "Claude-Config-Path",
                                 f"PATH ~/.local/bin ({target.name})")
    finally:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)


# --- settings.json（setup.sh render_settings_template / merge_settings_json / ensure_settings_json） ---

LEGACY_PLUGIN_KEYS = {"ecc@ecc", "affaan-m/everything-claude-code@ecc"}
LEGACY_HOOK_COMMANDS = {"rtk hook claude", "rtk-rewrite"}


def render_settings_template(tmpl: Path) -> str:
    def env(*names: str) -> str:
        for name in names:
            value = os.environ.get(name)
            if value:
                return value
        return ""

    content = tmpl.read_text(encoding="utf-8")
    substitutions = {
        "{{CLAUDE_BASE_URL}}": env("CLAUDE_BASE_URL", "ANTHROPIC_BASE_URL"),
        "{{CLAUDE_API_KEY}}": env("CLAUDE_API_KEY", "ANTHROPIC_AUTH_TOKEN"),
        "{{CLAUDE_MODEL}}": env("CLAUDE_MODEL", "ANTHROPIC_MODEL"),
        "{{CLAUDE_HAIKU_MODEL}}": env("CLAUDE_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
        "{{CLAUDE_SONNET_MODEL}}": env("CLAUDE_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
        "{{CLAUDE_OPUS_MODEL}}": env("CLAUDE_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
        "{{REPO_ROOT}}": str(util.repo_root()),
    }
    for key, value in substitutions.items():
        content = content.replace(key, value)
    return content


def _merge_missing(existing, template, skip_empty=False):
    """只补缺失键：已有标量/列表保留，dict 递归合并，'' 视为空可跳过。"""
    if skip_empty and template == "":
        return existing
    if isinstance(existing, dict) and isinstance(template, dict):
        merged = dict(existing)
        for key, value in template.items():
            if skip_empty and value == "":
                continue
            if key in merged:
                merged[key] = _merge_missing(merged[key], value, skip_empty=skip_empty)
            else:
                merged[key] = _merge_missing(None, value, skip_empty=skip_empty)
        return merged
    if isinstance(existing, list):
        return list(existing)
    if isinstance(template, list):
        return list(template)
    if existing is None:
        return template
    return existing


def _pop_legacy_plugin_keys(current: dict) -> bool:
    """清理 settings 里的旧 ECC plugin/marketplace 条目；返回是否变更。"""
    changed = False
    enabled = current.get("enabledPlugins")
    if isinstance(enabled, dict):
        for key in LEGACY_PLUGIN_KEYS:
            if enabled.pop(key, None) is not None:
                changed = True
    marketplaces = current.get("extraKnownMarketplaces")
    if isinstance(marketplaces, dict) and marketplaces.pop("ecc", None) is not None:
        changed = True
    return changed


def _clean_legacy_hooks(current: dict) -> bool:
    """移除旧 RTK hook 命令（整组 hooks 被清空则丢弃该组）；返回是否变更。"""
    hooks = current.get("hooks")
    if not isinstance(hooks, dict):
        return False
    changed = False
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        cleaned_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                cleaned_groups.append(group)
                continue
            kept = [
                hook for hook in group["hooks"]
                if not (isinstance(hook, dict) and hook.get("command") in LEGACY_HOOK_COMMANDS)
            ]
            if kept != group["hooks"]:
                changed = True
                if kept:
                    updated = dict(group)
                    updated["hooks"] = kept
                    cleaned_groups.append(updated)
            else:
                cleaned_groups.append(group)
        hooks[event] = cleaned_groups
        if cleaned_groups != groups:
            changed = True
    return changed


def merge_settings_json(target: Path, rendered_template: str) -> None:
    current = json.loads(target.read_text(encoding="utf-8"))
    template = json.loads(rendered_template)

    current = _merge_missing(current, template, skip_empty=True)
    enabled = current.get("enabledPlugins")
    current["enabledPlugins"] = dict(enabled) if isinstance(enabled, dict) else {}
    _pop_legacy_plugin_keys(current)
    _clean_legacy_hooks(current)

    target.write_text(json.dumps(current, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")


def ensure_settings_json(agent) -> None:
    root = util.repo_root()
    template = root / "claude" / "settings.template.json"
    home = agent.skills_dir.parent
    target = home / "settings.json"

    if not template.is_file():
        util.warn("settings.template.json 不存在，跳过")
        return

    rendered = render_settings_template(template)
    remove_legacy_settings_entries(target)

    # 已存在则始终合并（保留已有值，仅补齐模板缺失键），不区分 CI_MODE。
    if target.is_file():
        util.info("合并现有 settings.json（保留已有值，仅补齐缺失项）...")
        if util.DRY_RUN:
            util.dry("merge settings.json with template-backed migration keys")
            return
        home.mkdir(parents=True, exist_ok=True)
        merge_settings_json(target, rendered)
        util.log("settings.json 已合并并补齐缺失项")
        return

    util.info("生成 settings.json...")
    if util.DRY_RUN:
        util.dry("write rendered settings.json")
        return
    home.mkdir(parents=True, exist_ok=True)
    target.write_text(rendered + "\n", encoding="utf-8")
    util.log("settings.json 已生成")


# --- legacy 清理（script/install-common.sh 的语义迁移） ---

def remove_legacy_settings_entries(target: Path) -> None:
    if not target.is_file():
        return
    if util.DRY_RUN:
        util.info(f"[DRY-RUN] 清理 settings.json 中旧 ECC plugin 与 RTK hook: {target}")
        return
    data = json.loads(target.read_text(encoding="utf-8"))
    changed = _pop_legacy_plugin_keys(data)
    if _clean_legacy_hooks(data):
        changed = True
    if changed:
        target.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")


def remove_legacy_marketplace_entries(target: Path) -> None:
    if not target.is_file():
        return
    if util.DRY_RUN:
        util.info(f"[DRY-RUN] 清理 known_marketplaces.json 中旧 ecc 条目: {target}")
        return
    data = json.loads(target.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("known_marketplaces.json 顶层必须是对象")
    if data.pop("ecc", None) is not None:
        target.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")


def remove_legacy_installed_plugins_entries(target: Path) -> None:
    if not target.is_file():
        return
    if util.DRY_RUN:
        util.info(f"[DRY-RUN] 清理 installed_plugins.json 中旧 ECC 注册: {target}")
        return
    data = json.loads(target.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("installed_plugins.json 顶层必须是对象")
    changed = False
    for field in ("plugins", "enabledPlugins"):
        values = data.get(field)
        if isinstance(values, dict):
            for key in LEGACY_PLUGIN_KEYS:
                if values.pop(key, None) is not None:
                    changed = True
    if changed:
        target.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def remove_legacy_rtk_link(target: Path, expected_src: Path) -> None:
    if not target.is_symlink():
        return
    link_target = os.readlink(target)
    if link_target != str(expected_src) and os.path.realpath(target) != str(expected_src):
        return
    if util.DRY_RUN:
        util.dry(f"rm {target}")
        return
    target.unlink()
    util.log("已移除旧 RTK.md symlink")


def remove_legacy_ecc_paths(home: Path) -> None:
    for path in (home / "ecc", home / "plugins" / "cache" / "ecc",
                 home / "plugins" / "marketplaces" / "ecc", home / "skills" / "ecc"):
        if not (path.exists() or path.is_symlink()):
            continue
        if util.DRY_RUN:
            util.dry(f"rm -rf {path}")
            continue
        if path.is_symlink() or path.is_file():
            path.unlink()
        else:
            shutil.rmtree(path)
        util.log(f"已移除旧 ECC 路径: {path}")


# --- 核心同步（setup.sh ensure_core_config） ---

def ensure_core_config(agent) -> int:
    root = util.repo_root()
    repo = root / "claude"
    home = agent.skills_dir.parent
    home.mkdir(parents=True, exist_ok=True)

    remove_legacy_rtk_link(home / "RTK.md", repo / "RTK.md")
    remove_legacy_marketplace_entries(home / "plugins" / "known_marketplaces.json")
    remove_legacy_installed_plugins_entries(home / "plugins" / "installed_plugins.json")

    ensure_user_local_bin_path()

    failed = 0
    if not util.ensure_symlink(repo / "CLAUDE.md.ccfg", home / "CLAUDE.md", "CLAUDE.md symlink"):
        failed = 1
    # 注释掉的 itp/haiku symlink 不迁移（旧版已停用）。
    util.remove_symlink_if_ours(home / "AGENTS.md", "AGENTS.md 旧 symlink", repo / "AGENTS.md")
    if not util.ensure_symlink(repo / "rules", home / "rules", "rules symlink"):
        failed = 1
    if not util.ensure_symlink(repo / "rules-available", home / "rules-available", "rules-available symlink"):
        failed = 1
    if not util.ensure_symlink(repo / "hooks" / "rules-loader.sh", home / "hooks" / "rules-loader.sh", "rules-loader hook"):
        failed = 1
    # 自定义 subagent 目录（原 claude/agents-custom 已并入 claude/agents）
    if not util.ensure_symlink(repo / "agents", home / "agents", "agents symlink"):
        failed = 1
    return failed


def sync(agent) -> int:
    """core 子命令主体：核心配置 symlink 组 + settings.json 合并。"""
    if not getattr(agent, "core", False):
        util.info(f"{agent.key} 目标无核心配置，跳过 core 同步")
        return 0
    failed = ensure_core_config(agent)
    ensure_settings_json(agent)
    return failed


# --- 验证（setup.sh verify_core_config / verify_repository_cleanliness） ---

def verify_repository_cleanliness() -> bool:
    # --no-verify 由 cli 侧 gate（不调 verify 即跳过）；这里总是执行。
    root = util.repo_root()
    failed = False
    ignored_paths = ("package.json", "package-lock.json", "claude/AGENTS.md")
    for rel in ignored_paths:
        tracked = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", rel],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
        if tracked:
            util.err(f"路径仍被 git 跟踪，不能只依赖 .gitignore: {rel}")
            failed = True
        else:
            ignored = subprocess.run(
                ["git", "-C", str(root), "check-ignore", "-q", "--", rel],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode == 0
            if ignored:
                util.info(f"已忽略且未跟踪: {rel}")
            else:
                util.err(f"缺少忽略规则: {rel}")
                failed = True

        dirty = subprocess.run(
            ["git", "-C", str(root), "diff", "--quiet", "--", rel],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode != 0
        if dirty:
            util.err(f"路径仍产生 tracked diff: {rel}")
            failed = True
    return not failed


def verify_core_config(agent) -> bool:
    # --no-verify 由 cli 侧 gate（不调 verify 即跳过）；这里总是执行。
    root = util.repo_root()
    repo = root / "claude"
    home = agent.skills_dir.parent
    failed = False

    claude_md = home / "CLAUDE.md"
    ccfg_src = repo / "CLAUDE.md.ccfg"
    if _is_valid_claude_md(claude_md, ccfg_src):
        if _symlink_points_to(claude_md, ccfg_src):
            util.info("CLAUDE.md symlink")
        else:
            util.info("CLAUDE.md injected file (OMC + Claude-Config)")
    else:
        if claude_md.is_file() and not claude_md.is_symlink():
            util.err("CLAUDE.md 是普通文件但缺少 OMC 或 Claude-Config block")
        else:
            util.err("CLAUDE.md 未配置 (需要 symlink 或包含 OMC + Claude-Config blocks 的普通文件)")
        failed = True

    agents_path = home / "AGENTS.md"
    if not agents_path.exists() and not agents_path.is_symlink():
        util.info("AGENTS.md 未由核心配置接管")
    elif agents_path.is_symlink():
        agents_target = os.path.realpath(agents_path)
        if agents_target == str(repo / "AGENTS.md"):
            util.err("AGENTS.md 不应再链接到仓库内第三方内容")
            failed = True
        else:
            util.warn(f"AGENTS.md 是外部符号链接，核心 setup 不接管: {agents_path} -> {agents_target}")
    elif agents_path.is_file():
        util.info(f"AGENTS.md 是用户管理文件，核心 setup 不接管: {agents_path}")
    else:
        util.warn(f"AGENTS.md 存在但类型不常见，核心 setup 不接管: {agents_path}")

    for rel, label in (
        ("rules", "rules symlink"),
        ("rules-available", "rules-available symlink"),
        ("hooks/rules-loader.sh", "rules-loader hook"),
        ("agents", "agents symlink"),
    ):
        if _symlink_points_to(home / rel, repo / rel):
            util.info(label)
        else:
            util.err(f"{label} 缺失")
            failed = True

    repo_skills_dir = root / "skills"
    if repo_skills_dir.is_dir() and any(repo_skills_dir.iterdir()):
        util.info(f"自有 skills 就绪 ({repo_skills_dir})")
    else:
        util.err(f"自有 skills 目录缺失或为空: {repo_skills_dir}")
        failed = True

    if (home / "settings.json").is_file():
        util.info("settings.json 已存在")
    else:
        util.err("settings.json 不存在")
        failed = True

    if (home / "plugins" / "known_marketplaces.json").is_file():
        util.info("known_marketplaces.json 已存在")
    else:
        util.warn("known_marketplaces.json 不存在（首次安装时装 plugin 后会自动生成，可接受）")

    if not verify_repository_cleanliness():
        failed = True
    return not failed


def verify(agent) -> int:
    if not getattr(agent, "core", False):
        util.info(f"{agent.key} 目标无核心配置，跳过 verify")
        return 0
    return 0 if verify_core_config(agent) else 1


# --- 卸载（setup.sh remove_managed_block / uninstall_core / uninstall_all 的清理面） ---

def remove_managed_block(path: Path, block_name: str, label: str) -> None:
    """从 CLAUDE.md 类文件移除受管块（HTML marker 格式）；文件清空则删除。"""
    if not path.is_file():
        return
    start_re = rf"<!--\s*{re.escape(block_name)}:START\s*-->"
    if re.search(start_re, path.read_text(encoding="utf-8", errors="replace")) is None:
        return
    if util.DRY_RUN:
        util.dry(f"remove {block_name} block from {path}")
        return

    end_re = rf"<!--\s*{re.escape(block_name)}:END\s*-->"
    pattern = re.compile(rf"(?ms)^\s*{start_re}\s*\n.*?\n{end_re}\s*")
    updated = pattern.sub("", path.read_text(encoding="utf-8"), count=1).strip() + "\n"
    if updated.strip():
        path.write_text(updated, encoding="utf-8")
    else:
        path.unlink()
    util.log(f"已移除: {label}")


def uninstall_core(agent) -> int:
    """核心配置卸载：symlink 组、CLAUDE.md 受管块、legacy 清理面。

    绝不触碰仓库 skills/ 源文件与 configs/；settings.json 保留（可能含用户自定义）。
    """
    if not getattr(agent, "core", False):
        util.info(f"{agent.key} 目标无核心配置，跳过 uninstall core")
        return 0

    util.phase("Uninstall: 核心配置")
    root = util.repo_root()
    repo = root / "claude"
    home = agent.skills_dir.parent

    claude_md = home / "CLAUDE.md"
    if claude_md.is_symlink():
        util.remove_symlink_if_ours(claude_md, "CLAUDE.md symlink", repo / "CLAUDE.md.ccfg")
    elif claude_md.is_file() and _file_has_block(claude_md, "Claude-Config"):
        remove_managed_block(claude_md, "Claude-Config", "CLAUDE.md Claude-Config block")

    remove_legacy_rtk_link(home / "RTK.md", repo / "RTK.md")
    util.remove_symlink_if_ours(home / "AGENTS.md", "AGENTS.md", repo / "AGENTS.md")
    util.remove_symlink_if_ours(home / "rules", "rules/", repo / "rules")
    util.remove_symlink_if_ours(home / "rules-available", "rules-available/", repo / "rules-available")
    util.remove_symlink_if_ours(home / "hooks" / "rules-loader.sh", "rules-loader hook", repo / "hooks" / "rules-loader.sh")
    util.remove_symlink_if_ours(home / "agents", "agents/", repo / "agents")

    # 只摘除指向仓库 skills/ 的 symlink 副本，绝不写仓库侧。
    repo_skills_dir = repo / "skills"
    target_skills = home / "skills"
    if repo_skills_dir.is_dir() and target_skills.is_dir():
        for skill_src in sorted(repo_skills_dir.iterdir()):
            if not skill_src.exists():
                continue
            util.remove_symlink_if_ours(target_skills / skill_src.name,
                                        f"repo skill '{skill_src.name}'", skill_src)

    hooks_dir = home / "hooks"
    if hooks_dir.is_dir():
        try:
            hooks_dir.rmdir()
            util.info("已清理空 hooks 目录")
        except OSError:
            pass

    remove_legacy_settings_entries(home / "settings.json")
    remove_legacy_marketplace_entries(home / "plugins" / "known_marketplaces.json")
    remove_legacy_installed_plugins_entries(home / "plugins" / "installed_plugins.json")
    remove_legacy_ecc_paths(home)

    known_marketplaces = home / "plugins" / "known_marketplaces.json"
    if util.DRY_RUN:
        util.dry(f"rm {known_marketplaces}")
    else:
        known_marketplaces.unlink(missing_ok=True)
        util.log("已移除 known_marketplaces.json")
    util.info(f"settings.json 未被移除 (可能包含自定义配置)。如需重置: rm {home}/settings.json")
    return 0


# --- 自检（无框架 assert 风格，照仓库现状） ---

if __name__ == "__main__":
    _base = Path(tempfile.mkdtemp(prefix="launch-core-selftest-"))
    try:
        os.environ["HOME"] = str(_base)
        os.environ["SHELL"] = "/bin/bash"
        os.environ["CLAUDE_CONFIG_DIR"] = str(_base / "claude-home")
        os.environ.pop("LAUNCH_REPO_ROOT", None)

        class _Agent:  # agents.AgentSpec 形状的鸭子类型
            key = "claude"
            core = True
            skills_dir = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "skills"

        _agent = _Agent()
        _home = _agent.skills_dir.parent

        # 1) dry-run 全路径无副作用
        util.DRY_RUN = True
        assert sync(_agent) == 0
        assert not _home.exists() or not any(_home.iterdir()), "dry-run 不应创建 claude home 内容"
        assert not (_base / ".profile").exists(), "dry-run 不应写 RC"
        assert not (_base / ".bashrc").exists(), "dry-run 不应写 RC"

        # 2) 真实同步
        util.DRY_RUN = False
        assert sync(_agent) == 0
        assert (_home / "CLAUDE.md").is_symlink()
        for _rel in ("rules", "rules-available", "agents", "hooks/rules-loader.sh"):
            assert (_home / _rel).is_symlink(), _rel
        _profile = (_base / ".profile").read_text(encoding="utf-8")
        assert "# Claude-Config-Path:START" in _profile
        assert "# Claude-Config-Path:START" in (_base / ".bashrc").read_text(encoding="utf-8")
        _settings = json.loads((_home / "settings.json").read_text(encoding="utf-8"))
        assert _settings["model"] == "sonnet"
        assert _settings["enabledPlugins"]["superpowers@superpowers"] is True
        assert _settings["env"]["DISABLE_AUTOUPDATER"] == "1"
        assert _settings["hooks"]["PreToolUse"][0]["matcher"] == "Edit|Write"

        # 3) 幂等：重复 sync 不产生重复块、settings 不丢用户键
        (_home / "settings.json").write_text(
            json.dumps({"model": "opus", "custom_user_key": 1}, indent=4) + "\n", encoding="utf-8")
        assert sync(_agent) == 0
        assert (_base / ".profile").read_text(encoding="utf-8").count("Claude-Config-Path:START") == 1
        _settings = json.loads((_home / "settings.json").read_text(encoding="utf-8"))
        assert _settings["custom_user_key"] == 1, "合并必须保留用户自建键"
        assert _settings["theme"] == "dark", "缺失键应从模板补齐"

        # 4) RC 块 legacy <!-- --> 格式迁移到 # 格式
        (_base / ".bashrc").write_text(
            "<!-- Claude-Config-Path:START -->\n"
            "<!-- hash:0123456789abcdef -->\n"
            "case \":$PATH:\" in\n"
            "  *\":$HOME/.local/bin:\"*) ;;\n"
            "  *) export PATH=\"$HOME/.local/bin:$PATH\" ;;\n"
            "esac\n"
            "<!-- Claude-Config-Path:END -->\n", encoding="utf-8")
        ensure_user_local_bin_path()
        _bashrc = (_base / ".bashrc").read_text(encoding="utf-8")
        assert "<!-- Claude-Config-Path" not in _bashrc, "legacy HTML marker 应迁移"
        assert _bashrc.count("# Claude-Config-Path:START") == 1

        # 5) legacy settings 清理（ECC plugin/marketplace + RTK hooks）
        _legacy = _home / "legacy-settings.json"
        _legacy.write_text(json.dumps({
            "enabledPlugins": {"ecc@ecc": True, "keep@x": True},
            "extraKnownMarketplaces": {"ecc": {}, "omc": {}},
            "hooks": {"SessionStart": [
                {"hooks": [{"command": "rtk hook claude", "type": "command"},
                           {"command": "keep-cmd", "type": "command"}]},
                {"matcher": "m", "hooks": [{"command": "rtk-rewrite", "type": "command"}]},
            ]},
        }, indent=4), encoding="utf-8")
        remove_legacy_settings_entries(_legacy)
        _data = json.loads(_legacy.read_text(encoding="utf-8"))
        assert "ecc@ecc" not in _data["enabledPlugins"] and "keep@x" in _data["enabledPlugins"]
        assert "ecc" not in _data["extraKnownMarketplaces"] and "omc" in _data["extraKnownMarketplaces"]
        assert len(_data["hooks"]["SessionStart"]) == 1
        assert _data["hooks"]["SessionStart"][0]["hooks"][0]["command"] == "keep-cmd"

        # 6) 验证（含仓库洁净检查）
        assert verify(_agent) == 0

        # 7) 卸载：symlink 摘除、settings 保留、空 hooks 目录清理
        (_home / "plugins").mkdir(parents=True, exist_ok=True)
        (_home / "plugins" / "known_marketplaces.json").write_text(
            json.dumps({"ecc": {}, "omc": {}}), encoding="utf-8")
        assert uninstall_core(_agent) == 0
        assert not (_home / "CLAUDE.md").is_symlink() and not (_home / "CLAUDE.md").exists()
        for _rel in ("rules", "rules-available", "agents", "hooks/rules-loader.sh"):
            assert not (_home / _rel).is_symlink(), _rel
        assert not (_home / "hooks").exists(), "空 hooks 目录应被清理"
        assert (_home / "settings.json").is_file(), "settings.json 必须保留"
        assert not (_home / "plugins" / "known_marketplaces.json").exists()
        assert not (_base / "skills").exists(), "仓库 skills/ 源文件绝不能被卸载触碰"

        # 8) 注入式 CLAUDE.md（受管块普通文件）也能被卸载
        _md = _home / "CLAUDE.md"
        _md.write_text(
            "前文\n"
            "<!-- Claude-Config:START -->\n<!-- hash:abcd -->\n内容\n<!-- Claude-Config:END -->\n",
            encoding="utf-8")
        assert uninstall_core(_agent) == 0
        _md_text = _md.read_text(encoding="utf-8")
        assert "Claude-Config:START" not in _md_text and "前文" in _md_text

        print("core.py self-check OK")
    finally:
        shutil.rmtree(_base, ignore_errors=True)
