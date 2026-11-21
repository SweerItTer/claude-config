#!/usr/bin/env python3
"""launch CLI 主入口：argparse 装配 + 子命令路由。

exit code：0 成功、1 部分失败、2 用法错误（argparse 默认一致）。
无任何子命令与 flag → 打印 help → 0。

全局 flag 用 parent parser + default=SUPPRESS 挂到主 parser 和每个子 parser：
argparse 原生不支持「主 parser 的 flag 出现在子命令之后」，加共享 parent 后
`launch install --dry-run` 与 `launch --dry-run install` 等价；SUPPRESS 保证
先于子命令给出的值不会被子 parser 的默认值覆盖。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

if __package__ in (None, ""):  # 直接执行本文件时补 sys.path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from launch import core, manifest, plan, plugins, skills, updater, util
from launch.agents import resolve_agent


def _repo_root() -> Path:
    return util.repo_root()


def _config(name: str) -> Path:
    return _repo_root() / "configs" / name


# ---------- --ci 日志 tee ----------

class Tee:
    """stdout/stderr 同时写原流与日志文件。"""

    def __init__(self, path: Path):
        self.path = path
        self.file = open(path, "a", encoding="utf-8")
        self._orig_out = sys.stdout
        self._orig_err = sys.stderr

    def install(self) -> None:
        sys.stdout = self
        sys.stderr = self

    def write(self, data: str) -> int:
        self._orig_out.write(data)
        self.file.write(data)
        return len(data)

    def flush(self) -> None:
        self._orig_out.flush()
        self.file.flush()

    def close(self) -> None:
        sys.stdout = self._orig_out
        sys.stderr = self._orig_err
        self.file.close()


# ---------- argparse ----------

def _common_flags(p: argparse.ArgumentParser) -> argparse.ArgumentParser:
    """全局 flag（default=SUPPRESS：未给出时不写 namespace，主/子 parser 不互相覆盖）。"""
    p.add_argument("--agent", default=argparse.SUPPRESS,
                   help="目标 agent: claude(默认, 别名 claude-code) | agents")
    p.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS,
                   help="预览，不实际修改")
    p.add_argument("-y", "--yes", action="store_true", default=argparse.SUPPRESS,
                   help="跳过确认")
    p.add_argument("-v", "--verbose", action="store_true", default=argparse.SUPPRESS,
                   help="恢复逐项输出")
    p.add_argument("--no-color", action="store_true", default=argparse.SUPPRESS,
                   help="关闭 ANSI 颜色")
    p.add_argument("--ci", action="store_true", default=argparse.SUPPRESS,
                   help="CI 模式（完整日志写临时文件）")
    p.add_argument("--no-verify", action="store_true", default=argparse.SUPPRESS,
                   help="跳过验证")
    p.add_argument("--no-claude", action="store_true", default=argparse.SUPPRESS,
                   help="跳过 Claude Code 安装")
    p.add_argument("--force", action="store_true", default=argparse.SUPPRESS,
                   help="强制重跑（忽略幂等跳过）")
    p.add_argument("--skip", default=argparse.SUPPRESS, metavar="SKILLS,PLUGINS",
                   help="类别级跳过: skills,plugins（逗号多值）")
    p.add_argument("--smoke-test", action="store_true", default=argparse.SUPPRESS,
                   help="运行扩展冒烟检查")
    p.add_argument("--choose", action="append", default=argparse.SUPPRESS,
                   metavar="KIND:ID=CHOICE",
                   help="解决同名 local/remote 资源冲突（可重复；仅 update/uninstall）")
    p.add_argument("--tui", action="store_true", default=argparse.SUPPRESS,
                   help="启动交互式 TUI")
    return p


def build_parser() -> argparse.ArgumentParser:
    parser = _common_flags(argparse.ArgumentParser(
        prog="launch",
        description="Claude Code 配置迁移 CLI（替代 setup.sh）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "子命令:\n"
            "  install [names...]    装 skills（无 N=全量；--plugin N... 装第三方 plugin）\n"
            "  add <repo> <skill...> 试装第三方 skill，成功后追加 [[sources]] 进 skills.toml\n"
            "  remove <names...>     卸载 skills.toml 条目并从清单删除\n"
            "  uninstall <names...>  卸载（裸名先 skill 后 plugin；typed skill:/plugin: 直通；--all/--core）\n"
            "  update [names...]     无 N = git pull + 全量更新；N 可重复 = 指定项\n"
            "  list                  列已安装 skills（默认双 agent，==== 分隔）\n"
            "  core                  仅同步 claude 核心配置（claude 目标专属）\n"
            "  doctor                核心验证 + claude CLI/诊断/plugin 注册（--smoke-test 扩展冒烟）\n"
        ),
    ))
    sub = parser.add_subparsers(dest="command")

    common = lambda: _common_flags(argparse.ArgumentParser(add_help=False))  # noqa: E731

    p = sub.add_parser("install", parents=[common()], help="安装 skills / plugins")
    p.add_argument("names", nargs="*", help="skill 名（可重复；无=全量）")
    p.add_argument("--plugin", nargs="+", default=[], metavar="N",
                   help="第三方 plugin 名（可重复）")

    p = sub.add_parser("add", parents=[common()],
                       help="试装第三方 skill 并把 [[sources]] 追加进 skills.toml")
    p.add_argument("repo", metavar="OWNER/REPO", help="GitHub 仓库（owner/name 格式）")
    p.add_argument("skills", nargs="+", metavar="SKILL",
                   help="skill 名（SKILL.md frontmatter name 或目录 basename，可重复）")
    p.add_argument("--note", default="", help="可选备注文本，写入 note 字段")

    p = sub.add_parser("remove", parents=[common()],
                       help="卸载 skills.toml 条目并从清单删除（自有 skills/ 源不触碰）")
    p.add_argument("names", nargs="+", help="skills.toml 条目名（可重复）")

    p = sub.add_parser("uninstall", parents=[common()], help="卸载 skills / plugins / core")
    p.add_argument("names", nargs="*", help="目标名（可重复）")
    p.add_argument("--all", action="store_true", help="全量卸载（核心 + 清单全部）")
    p.add_argument("--core", action="store_true", help="仅核心配置")

    p = sub.add_parser("update", parents=[common()], help="更新仓库 / 指定项")
    p.add_argument("names", nargs="*", help="目标名（可重复；无=全量更新）")

    sub.add_parser("list", parents=[common()], help="列已安装 skills")
    sub.add_parser("core", parents=[common()], help="仅同步 claude 核心配置")
    sub.add_parser("doctor", parents=[common()],
                   help="诊断（verify + claude CLI + plugin 注册）")
    return parser


# ---------- uninstall 消歧 ----------

def _typed_split(name: str) -> tuple[str, str]:
    """'skill:N'/'plugin:N' → ('skill','N')；裸名 → ('', name)。"""
    for prefix in ("skill:", "plugin:"):
        if name.startswith(prefix):
            return prefix[:-1], name[len(prefix):]
    return "", name


def _uninstall_skill(name: str, agent) -> int:
    # 外部（npx skills remove）+ 自有（symlink 移除）各试一次；未安装侧报 0。
    rc = skills.uninstall([name], agent)
    if skills.uninstall_local([name], agent):
        rc = rc or 1
    return rc


def cmd_uninstall(names: list[str], agent, *, uninstall_all: bool, uninstall_core: bool) -> int:
    """裸名先 skill（skills.toml + local skills）后 plugin 消歧；typed 直通；
    --all/--core 串行先行，其余批量并发 3。"""
    rc = 0
    if uninstall_core or uninstall_all:
        if agent.key != "claude":
            util.err("--core/--all 卸载仅支持 --agent claude")
            return 2
        if core.uninstall_core(agent):
            rc = 1
        if uninstall_all:
            skill_sources = manifest.load_skills(_config("skills.toml"))
            local_names = manifest.local_skill_names(_repo_root())
            plugin_names = [p.name for p in manifest.load_plugins(_config("plugins.toml"))]
            with ThreadPoolExecutor(max_workers=3) as pool:
                futures = [pool.submit(_uninstall_skill, s.name, agent) for s in skill_sources]
                futures += [pool.submit(_uninstall_skill, n, agent) for n in local_names]
                futures += [pool.submit(plugins.uninstall, [n]) for n in plugin_names]
                for fut in futures:
                    if fut.result():
                        rc = 1
        if rc == 0:
            util.log("卸载完成 (core/all)")
        else:
            util.err("卸载未全部完成")
        return rc

    if not names:
        util.err("uninstall 需要目标: <names...> / --core / --all")
        return 2

    skill_names = {s.name for s in manifest.load_skills(_config("skills.toml"))} \
        | set(manifest.local_skill_names(_repo_root()))
    plugin_names = {p.name for p in manifest.load_plugins(_config("plugins.toml"))}

    jobs: list[tuple[str, str]] = []
    for raw in names:
        kind, name = _typed_split(raw)
        if kind:
            jobs.append((kind, name))
        elif name in skill_names:
            jobs.append(("skill", name))
        elif name in plugin_names:
            jobs.append(("plugin", name))
        else:
            util.err(f"未知卸载目标: {raw} (skills.toml/local skills/plugins.toml 均未命中)")
            rc = 2

    if jobs:
        def _one(job: tuple[str, str]) -> int:
            kind, name = job
            if kind == "skill":
                return _uninstall_skill(name, agent)
            return plugins.uninstall([name])

        with ThreadPoolExecutor(max_workers=3) as pool:
            for result in pool.map(_one, jobs):
                if result and rc != 2:
                    rc = 1

    if rc == 0:
        util.log(f"卸载完成 ({' '.join(names)})")
    else:
        util.err("卸载未全部完成")
    return rc


# ---------- update / install / list / core ----------

def _parse_choices(values: list[str]) -> dict[str, str]:
    """'kind:id=choice' 重复项 → dict；格式错退出 2。"""
    choices: dict[str, str] = {}
    for raw in values:
        key, sep, value = raw.partition("=")
        if not sep or ":" not in key or value not in ("local", "remote", "skip"):
            util.err(f"--choose 格式必须为 kind:id=local|remote|skip: {raw}")
            sys.exit(2)
        choices[key] = value
    return choices


def _ensure_claude_code() -> None:
    """确保 claude CLI 存在：缺失时 npm -g 安装；CLAUDE_HOME 缺失时后台启动初始化（幂等）。"""
    from launch.agents import resolve_agent
    claude_home = resolve_agent("claude").skills_dir.parent
    if shutil.which("claude"):
        version = subprocess.run(["claude", "--version"], capture_output=True, text=True)
        line = ((version.stdout or "") + (version.stderr or "")).strip().splitlines()
        util.log(f"Claude Code 已安装: {line[0] if line else '?'}")
        if not claude_home.is_dir():
            if util.DRY_RUN:
                util.dry("后台启动 Claude Code 初始化 CLAUDE_HOME")
            else:
                subprocess.Popen(["claude"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                util.info("Claude Code 已在后台启动初始化")
        return
    util.info("安装 Claude Code...")
    if util.DRY_RUN:
        util.dry("npm install -g @anthropic-ai/claude-code")
        return
    if subprocess.run(["npm", "install", "-g", "@anthropic-ai/claude-code"]).returncode != 0:
        util.err("Claude Code 安装失败")
        sys.exit(1)
    util.log("Claude Code 安装完成")
    # 后台启动一次触发初始化（目录/信任），不等待。
    subprocess.Popen(["claude"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    util.info("Claude Code 已在后台启动")


def cmd_install(args, agent) -> int:
    root = _repo_root()
    skip = {s.strip() for s in (getattr(args, "skip", "") or "").split(",") if s.strip()}

    if args.plugin:
        if agent.key != "claude":
            util.err("plugins 仅支持 --agent claude")
            return 2
        if skip:
            util.err("--skip 与 --plugin 不能同时使用")
            return 2
        return plugins.install(args.plugin)

    names = list(args.names or [])
    sources = manifest.load_skills(_config("skills.toml"))
    local_names = manifest.local_skill_names(root)
    if names:
        known = {s.name for s in sources} | set(local_names)
        unknown = [n for n in names if n not in known]
        if unknown:
            util.err(f"未知的 skill 名: {' '.join(unknown)}")
            util.info(f"合法名: {' '.join(sorted(known))}")
            return 2
    if skip and names:
        util.err("--skip 与指定名安装不能同时使用")
        return 2

    if agent.key != "claude":
        # 非 claude 目标：只装 skills（外部 npx universal + local symlink），其余一律跳过
        rc = 0
        util.phase("Phase 1: Agents skills（外部，npx skills）")
        if "skills" not in skip and skills.install(sources, agent, names=names,
                                                   force=getattr(args, "force", False)):
            rc = 1
        local = local_names if not names else [n for n in names if n in set(local_names)]
        util.phase("Phase 2: Agents skills（仓库自有，symlink）")
        if "skills" not in skip and skills.install_local(local, agent):
            rc = 1
        if rc == 0:
            util.log(f"Agents skills 安装完成 (--agent {agent.key})")
            util.info("非 claude 模式只安装 skills，未安装任何 claude 配置/plugins")
        else:
            util.err("部分 Agents skill 安装失败")
        return rc

    # claude 全流程
    missing = util.check_dependencies()
    if missing:
        util.err(f"缺少依赖: {' '.join(missing)}")
        return 1

    rc = 0
    util.phase("Phase 1: Claude Code")
    if getattr(args, "no_claude", False):
        util.info("跳过 Claude Code 安装 (--no-claude)")
    else:
        _ensure_claude_code()

    util.phase("Phase 2: 核心配置")
    if core.sync(agent):
        rc = 1

    util.phase("Phase 3: 外部 skills（npx skills）")
    if "skills" not in skip and skills.install(sources, agent, names=names,
                                               force=getattr(args, "force", False)):
        rc = 1

    # 仓库自有 skills（symlink）：与 agents 分支同一语义——指定名只装指定的，无参全量。
    util.phase("Phase 3.5: 仓库自有 skills（symlink）")
    if "skills" not in skip:
        local = [n for n in names if n in set(local_names)] if names else local_names
        if skills.install_local(local, agent):
            rc = 1

    # 单项 skill 安装是单项入口：没同时指定 plugin 时，装完即退出，
    # 不继续全量 plugin 安装和验证流程（旧语义照搬）。
    if names and not args.plugin:
        util.info("指定 skill 安装完成，跳过后续 plugins/验证流程")
        return rc

    util.phase("Phase 4: 第三方 plugins（claude plugin）")
    if "plugins" not in skip and plugins.install([]):
        rc = 1

    util.phase("Phase 5: 最终验证")
    # ponytail: dry-run 跳过验证——旧 bash 里 verify rc 被丢弃，等效于 dry-run 不验证；
    # 未落盘状态跑 verify 必报缺 symlink，把预览误判成失败。
    if not getattr(args, "no_verify", False) and not util.DRY_RUN:
        if core.verify(agent):
            rc = 1
        from launch import doctor as doctor_mod
        if doctor_mod.run(smoke=getattr(args, "smoke_test", False), no_verify=False):
            rc = 1

    if rc == 0:
        util.log("Claude Code 配置迁移完成!")
        if util.DRY_RUN:
            util.dry("(dry-run 预览，未做任何修改)")
    else:
        util.err("安装存在失败项")
    return rc


def cmd_update(args, agent) -> int:
    names = list(args.names or [])

    if not names:
        rc = updater.update_repo()
        if skills.update([], agent):
            rc = 1
        if agent.plugins and plugins.update([]):
            rc = 1
        if rc == 0:
            util.log("仓库 + 全部外部 skills + plugins 已更新")
        else:
            util.err("部分更新失败")
        return rc

    choices = _parse_choices(getattr(args, "choose", None) or [])
    skill_sources = manifest.load_skills(_config("skills.toml"))
    skill_names = {s.name for s in skill_sources}
    local_names = set(manifest.local_skill_names(_repo_root()))
    plugin_names = {p.name for p in manifest.load_plugins(_config("plugins.toml"))}

    rc = 0
    if choices:
        # --choose：交给 plan_resources 解冲突后逐项 update
        requests = []
        for raw in names:
            kind, name = _typed_split(raw)
            if not kind:
                kind = "skill" if name in (skill_names | local_names) else "plugin"
            requests.append(f"{kind}:{name}")
        try:
            result = plan.plan_resources(_repo_root(), requests, choices=choices)
        except ValueError as exc:
            util.err(f"资源计划失败: {exc}")
            return 2
        if result.conflicts:
            for c in result.conflicts:
                util.err(f"资源冲突未决: {c.kind}:{c.id} "
                         f"— 用 --choose {c.kind}:{c.id}=local|remote|skip 指定")
            return 2
        for item in result.items:
            if item.action == "skip":
                continue
            if item.kind == "skill":
                if item.source == "local":
                    # 自有 skill 是源码 symlink，即改即生效；update = 重铺 symlink
                    if skills.install_local([item.id], agent):
                        rc = 1
                elif skills.update([item.id], agent):
                    rc = 1
            elif plugins.update([item.id]):
                rc = 1
        if rc == 0:
            util.log("指定资源更新完成")
        else:
            util.err("部分资源更新失败")
        return rc

    for raw in names:
        kind, name = _typed_split(raw)
        if not kind:
            if name in skill_names or name in local_names:
                kind = "skill"
            elif name in plugin_names:
                kind = "plugin"
            else:
                util.err(f"未知更新目标: {raw}")
                rc = 2
                continue
        if kind == "skill":
            if name in local_names and name not in skill_names:
                if skills.install_local([name], agent):
                    rc = 1
            elif skills.update([name], agent):
                rc = 1
        elif plugins.update([name]):
            rc = 1

    if rc == 2:
        return 2
    if rc == 0:
        util.log("指定项更新完成")
    else:
        util.err("部分指定项更新失败")
    return rc


def cmd_list(args, agent) -> int:
    targets = [agent] if getattr(args, "agent", None) else [resolve_agent("claude"), resolve_agent("agents")]
    first = True
    for target in targets:
        if not first:
            print("====================")
        first = False
        entries = skills.installed(target)
        label = str(target.skills_dir).replace(str(Path.home()), "~", 1)
        print(f"=== {label} ({len(entries)}) ===")
        for entry in entries:
            print(f"{entry.name}\t{entry.source}\t{entry.detail or ''}")
        if not entries:
            util.info(f"{label} 为空")
    return 0


def cmd_core(args, agent) -> int:
    if agent.key != "claude":
        util.err("core 仅支持 --agent claude")
        return 2
    rc = core.sync(agent)
    if rc == 0:
        util.log("Claude Core 配置已同步!")
        if util.DRY_RUN:
            util.dry("(dry-run 预览，未做任何修改)")
    return rc


# ---------- add / remove ----------

def _valid_repo(repo: str) -> bool:
    """GitHub owner/name（恰好一个 '/'，两侧非空）。"""
    owner, sep, name = repo.partition("/")
    return sep != "" and "/" not in name and owner != "" and name != ""


def _reject_unsafe_names(names: list[str], what: str) -> list[str] | None:
    """外部参数边界：拒绝会被 shell/npx skills 展开的形态。

    npx skills 1.9.0 的 removeCommand 把字面 '*' 转成 --all；'-' 开头会被当 flag。
    命中即 err 并返回 None，调用方直接失败，绝不把这些值透传给 npx 或写进 toml。
    """
    bad = [n for n in names if n.strip() in ("", "*") or n.startswith("-")]
    if bad:
        util.err(f"{what} 不能是通配符或 flag 形态（'*' 会被 npx skills 当 --all 全量执行）: {bad!r}")
        return None
    return names


def _render_source_block(source: manifest.SkillSource) -> str:
    """SkillSource → [[sources]] TOML 块文本（字段序固定；note 可选，引号转义）。"""
    def q(v: str) -> str:
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'

    lines = ["[[sources]]",
             f"name = {q(source.name)}",
             f"repo = {q(source.repo)}",
             f"skill = {q(source.skill)}",
             f"agent = {q(source.agent)}",
             f"scope = {q(source.scope)}"]
    if source.note:
        lines.append(f"note = {q(source.note)}")
    return "\n".join(lines) + "\n"


def _atomic_write(path: Path, text: str) -> None:
    """tempfile + os.replace 原子替换（add 追加/remove 删块共用）。"""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            fp.write(text)
            fp.flush()
            os.fsync(fp.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _append_source(config: Path, source: manifest.SkillSource) -> None:
    """追加 [[sources]] 块到 skills.toml 文件尾（不重排、不破坏注释）。

    Ctrl-C 安全：块文本一次性 write + fsync 后才关句柄，最多留一个已 fsync 的完整块；
    老文件本身不动。绝不用全量重写（会破坏原文件格式）。"""
    block = _render_source_block(source)
    text = ""
    if config.is_file():
        text = config.read_text(encoding="utf-8")
    sep = "" if (not text or text.endswith("\n\n")) else ("\n" if text.endswith("\n") else "\n\n")
    with open(config, "a", encoding="utf-8") as fp:
        fp.write(sep + block)
        fp.flush()
        os.fsync(fp.fileno())


def _remove_source_blocks(config: Path, names: list[str]) -> tuple[int, int]:
    """按块边界（[[sources]] 起、下一 [[ 或 EOF 止）从 skills.toml 移除目标 name 的块。

    返回 (成功删除数, 畸形块数)。畸变块（块内无 name= 行）不删、由调用方置失败。
    原子替换：读全文 → 剔块 → tempfile+os.replace 写回；注释与非目标块原样保留。
    """
    remaining: list[str] = []
    removed = malformed = 0
    if config.is_file():
        text = config.read_text(encoding="utf-8")
        # 预扫描畸变块：任一目标名所在块缺 name= 行 → 整体中止（保持文件不动）
        for raw_block in text.split("[["):
            if not raw_block.startswith("sources]]"):
                continue
            body = raw_block[len("sources]]"):]
            head = body.split("[[", 1)[0]
            stripped = head.strip()
            if stripped.startswith("#") or not stripped:
                continue
            lines = [ln.strip() for ln in head.splitlines() if ln.strip() and not ln.strip().startswith("#")]
            if not any(ln.startswith("name ") or ln.startswith("name=") for ln in lines):
                malformed += 1
        if malformed:
            return 0, malformed
        lines = text.splitlines(keepends=True)
        i = 0
        in_sources = False
        cur_block: list[str] | None = None
        cur_name: str | None = None
        name_re = re.compile(r'^\s*name\s*=\s*"(.*)"\s*$')
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            # 边界：真表头 [[...]]，或注释掉的表头（# ...[[...]]，注释候选块不能被前面的块删除吞掉）
            is_table = stripped.startswith("[[") and stripped.endswith("]]")
            is_commented_table = stripped.startswith("#") and "[[" in stripped
            if is_table or is_commented_table:
                # 上一个块收尾
                if cur_block is not None:
                    if in_sources and cur_name in names:
                        removed += 1
                    else:
                        remaining.extend(cur_block)
                if is_table:
                    table = stripped[2:-2].strip()
                    in_sources = (table == "sources")
                    if in_sources:
                        cur_block = [line]
                        cur_name = None
                    else:
                        cur_block = None
                        cur_name = None
                else:  # 注释表头：当前块结束，注释行归 remaining
                    in_sources = False
                    cur_block = None
                    cur_name = None
                    remaining.append(line)
                i += 1
                continue
            if in_sources and cur_block is not None:
                cur_block.append(line)
                m = name_re.match(line)
                if m and cur_name is None:
                    cur_name = m.group(1)
            else:
                remaining.append(line)
            i += 1
        if cur_block is not None:
            if in_sources and cur_name in names:
                removed += 1
            else:
                remaining.extend(cur_block)
        if removed:
            _atomic_write(config, "".join(remaining))
    return removed, malformed


def _pending_adds(args, agent) -> list[manifest.SkillSource]:
    """add 的共享前置：repo 校验 + 名字冲突预检（原子性：任一冲突整体不加）。"""
    sources = manifest.load_skills(_config("skills.toml"))
    existing = {s.name for s in sources}
    conflicts = [n for n in args.skills if n in existing]
    if conflicts:
        util.err(f"skills.toml 已有同名 skill，整体不加: {' '.join(sorted(set(conflicts)))}")
        util.err(f"现有名: {' '.join(sorted(existing))}")
        return []
    agent_key = agent.npx_key
    return [manifest.SkillSource(name=n, repo=args.repo, skill=n,
                                 agent=agent_key, scope="global",
                                 note=getattr(args, "note", "") or "") for n in args.skills]


def cmd_add(repo: str, skills_names: list[str], args, agent) -> int:
    """add <repo> <skill...>：试装校验后追加 [[sources]] 到 skills.toml。"""
    if not _valid_repo(repo):
        util.err(f"repo 必须是 owner/name 格式（恰好一个 '/'）: {repo!r}")
        util.info("用法: launch add <owner/repo> <skill...> [--agent claude|agents] [--note <text>]")
        return 2
    if _reject_unsafe_names(skills_names, "add 的 skill 名") is None:
        return 2
    args.skills = skills_names
    sources = _pending_adds(args, agent)
    if not sources:
        return 1
    if util.DRY_RUN:
        for src in sources:
            util.dry(f"试装: {' '.join(skills._add_args(src.repo, [src.skill], agent.npx_key, src.scope))}")
            util.dry(f"将追加到 {_config('skills.toml')}:\n{_render_source_block(src)}")
        util.info(f"后续: launch install {' '.join(s.name for s in sources)} / launch remove <name>")
        return 0
    rc = skills.install(sources, agent, names=[s.skill for s in sources])
    if rc != 0:
        util.err("试装失败，skills.toml 未改动")
        return 1
    config = _config("skills.toml")
    for src in sources:
        _append_source(config, src)
        util.log(f"已追加到 skills.toml: {src.name}")
    util.log("add 完成")
    util.info(f"后续: launch install {' '.join(s.name for s in sources)} / launch remove <name>")
    return 0


def cmd_remove(names: list[str], args, agent) -> int:
    """remove <name...>：卸载已装副本 + 从 skills.toml 删条目；永不触碰仓库 skills/ 源。"""
    if _reject_unsafe_names(names, "remove 的名字") is None:
        return 2
    sources = manifest.load_skills(_config("skills.toml"))
    by_name = {s.name: s for s in sources}
    missing = [n for n in names if n not in by_name]
    hits = [n for n in names if n in by_name]
    if missing:
        util.err(f"skills.toml 中不存在的 skill: {' '.join(missing)}")
        util.err(f"合法名: {' '.join(sorted(by_name))}")
    if not hits:
        return 1
    rc = 1 if missing else 0
    if util.DRY_RUN:
        for n in hits:
            util.dry(f"卸载 skill: {n}")
            util.dry(f"将删除 {_config('skills.toml')} 中 name = \"{n}\" 的 [[sources]] 块")
        return rc
    for n in hits:
        if _uninstall_skill(n, agent):
            rc = 1
        removed, malformed = _remove_source_blocks(_config("skills.toml"), [n])
        if malformed:
            util.err(f"skills.toml 块格式畸变（缺 name= 行），跳过: {n}")
            rc = 1
        elif removed == 0:
            util.err(f"skills.toml 未找到可删除的块: {n}")
            rc = 1
        else:
            util.log(f"已从 skills.toml 删除条目: {n}")
    if rc == 0:
        util.log(f"remove 完成 ({' '.join(hits)})")
    else:
        util.err("remove 未全部完成")
    return rc


# ---------- main ----------

def _route(args, agent) -> int:
    cmd = args.command
    if cmd is None:
        # 只有全局 flag、无子命令：不隐式安装，给用法提示（裸跑=help 的硬性要求延伸）。
        print("未指定子命令:", file=sys.stderr)
        build_parser().print_help(file=sys.stderr)
        return 2
    if cmd == "install":
        return cmd_install(args, agent)
    if cmd == "add":
        return cmd_add(args.repo, args.skills, args, agent)
    if cmd == "remove":
        return cmd_remove(args.names, args, agent)
    if cmd == "uninstall":
        if args.all and args.core:
            util.err("--all 与 --core 不能同时使用")
            return 2
        return cmd_uninstall(args.names, agent,
                             uninstall_all=args.all, uninstall_core=args.core)
    if cmd == "update":
        return cmd_update(args, agent)
    if cmd == "list":
        return cmd_list(args, agent)
    if cmd == "core":
        return cmd_core(args, agent)
    if cmd == "doctor":
        from launch import doctor as doctor_mod
        return doctor_mod.run(smoke=getattr(args, "smoke_test", False),
                              no_verify=getattr(args, "no_verify", False))
    util.err(f"未处理的子命令: {cmd}")
    return 2


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)

    # 硬性要求：无任何子命令与 flag → 打印 help → 0，不安装任何东西。
    if not raw:
        build_parser().print_help()
        return 0

    parser = build_parser()
    try:
        args = parser.parse_args(raw)
    except SystemExit as exc:
        return int(exc.code or 0)

    # 全局开关 → util（SUPPRESS 缺省 → getattr 补默认）
    util.VERBOSE = getattr(args, "verbose", False) or getattr(args, "ci", False)
    util.DRY_RUN = getattr(args, "dry_run", False)
    util.CI_MODE = getattr(args, "ci", False)
    util.YES = getattr(args, "yes", False)
    util.FORCE = getattr(args, "force", False)
    if getattr(args, "no_color", False):
        util.RED = util.GREEN = util.YELLOW = util.BLUE = util.NC = ""
        os.environ["NO_COLOR"] = "1"

    agent = resolve_agent(getattr(args, "agent", "claude"))

    # 互斥校验：--choose 仅 update/uninstall 用
    choose = getattr(args, "choose", None)
    if choose and args.command not in ("update", "uninstall"):
        util.err("--choose 仅 update/uninstall 支持")
        return 2

    if getattr(args, "tui", False):
        from launch import tui  # E 切片提供
        return tui.run(agent.key)

    ci_tee = None
    if util.CI_MODE:
        ci_tee = Tee(Path(tempfile.mkstemp(prefix="launch-ci-", suffix=".log")[1]))
        ci_tee.install()
        util.log(f"CI 模式 — 完整日志: {ci_tee.path}")
    try:
        return _route(args, agent)
    finally:
        if ci_tee is not None:
            ci_tee.close()
            util.log(f"CI 完整日志: {ci_tee.path}")


if __name__ == "__main__":
    # 自检：parser 构建 + 无参 → help 0 + 未知子命令 → 2 + typed 拆分 + choose 解析
    p = build_parser()
    assert main([]) == 0                      # 无参 → help → 0
    assert main(["badcmd"]) == 2              # argparse 用法错误 → 2
    assert _parse_choices(["skill:x=local", "plugin:y=skip"])["skill:x"] == "local"
    assert _typed_split("skill:grilling") == ("skill", "grilling")
    assert _typed_split("plugin:ponytail") == ("plugin", "ponytail")
    assert _typed_split("grilling") == ("", "grilling")
    ns = p.parse_args(["--dry-run", "install", "grilling", "-v"])
    assert ns.dry_run and ns.verbose and ns.names == ["grilling"]   # 全局 flag 子命令前
    ns = p.parse_args(["install", "--dry-run", "grilling"])
    assert ns.dry_run and ns.names == ["grilling"]                  # 全局 flag 子命令后
    ns = p.parse_args(["--dry-run", "list"])
    assert ns.dry_run and ns.command == "list"
    # add/remove 纯函数自检
    assert _valid_repo("tt-a1i/archify")
    assert not _valid_repo("archify")            # 缺 '/'
    assert not _valid_repo("a/b/c")              # 两个 '/'
    assert not _valid_repo("/name")              # owner 空
    assert not _valid_repo("owner/")             # name 空
    # 通配符/flag 边界：'*' 会被 npx skills removeCommand 当 --all，'-' 开头当 flag
    assert _reject_unsafe_names(["ok"], "t") == ["ok"]
    assert _reject_unsafe_names(["*"], "t") is None
    assert _reject_unsafe_names(["-y"], "t") is None
    assert _reject_unsafe_names(["", "*"], "t") is None
    assert _reject_unsafe_names(["skill-*"], "t") == ["skill-*"]  # 后缀通配放行（install 阶段自然失败）
    src = manifest.SkillSource(name="x\"y\\z", repo="o/r", skill="s",
                               agent="claude-code", scope="global", note='a"b')
    block = _render_source_block(src)
    assert block.startswith("[[sources]]\nname = \"x\\\"y\\\\z\"\n")
    assert 'note = "a\\"b"' in block
    # 注意：3.10 手写解析器不 unescape，含引号/反斜杠值的往返只有 tomllib(≥3.11) 保证；
    # 往返断言用普通值（真实 note 是中文散文，不含这些字符）。
    plain = manifest.SkillSource(name="plain-name", repo="o/r", skill="s",
                                 agent="claude-code", scope="global", note="中文备注")
    ns = p.parse_args(["add", "o/r", "s1", "s2", "--note", "测试"])
    assert ns.repo == "o/r" and ns.skills == ["s1", "s2"] and ns.note == "测试"
    ns = p.parse_args(["remove", "a", "b"])
    assert ns.names == ["a", "b"]
    # remove 块删除：无文件 → 0 删 0 畸形；典型块 → 删 1；注释块/其他表不动；缺 name= 畸形
    with tempfile.TemporaryDirectory() as tmpd:
        cfg = Path(tmpd) / "skills.toml"
        before = 0, 0
        assert _remove_source_blocks(cfg, ["x"]) == before      # 文件不存在
        cfg.write_text(
            "# 头注释\n"
            "[[sources]]\n"
            'name = "grilling"\n'
            'repo = "m/s"\n'
            "\n"
            "# [[sources]]\n"
            '# name = "commented"\n'
            '# repo = "m/s"\n'
            "\n"
            "[[sources]]\n"
            'repo = "no-name"\n'
            "\n"
            "[[sources]]\n"
            'name = "wayfinder"\n'
            'repo = "m/s"\n'
            'note = "尾块"\n',
            encoding="utf-8")
        removed, malformed = _remove_source_blocks(cfg, ["grilling"])
        assert (removed, malformed) == (0, 1), (removed, malformed)  # 畸形块 → 整体中止
        assert "grilling" in cfg.read_text(encoding="utf-8")
        cfg.write_text(
            "# 头注释\n"
            "[[sources]]\n"
            'name = "grilling"\n'
            'repo = "m/s"\n'
            "\n"
            "# [[sources]]\n"
            '# name = "commented"\n'
            "\n"
            "[[sources]]\n"
            'name = "wayfinder"\n'
            'repo = "m/s"\n'
            'note = "尾块"\n',
            encoding="utf-8")
        original = cfg.read_text(encoding="utf-8")
        removed, malformed = _remove_source_blocks(cfg, ["grilling", "not-there"])
        assert (removed, malformed) == (1, 0), (removed, malformed)
        after = cfg.read_text(encoding="utf-8")
        assert 'name = "grilling"' not in after
        assert "# 头注释" in after and 'name = "wayfinder"' in after
        assert "# [[sources]]" in after                      # 注释块原样保留
        assert original.count("[[sources]]") - after.count("[[sources]]") == 1
        # _append_source：无文件从零建；已删块重加；中文 note 往返
        _append_source(cfg, plain)
        reloaded = manifest.load_skills(cfg)
        assert reloaded[-1].name == "plain-name" and reloaded[-1].note == "中文备注"
    print("cli self-check ok", file=sys.stderr)
