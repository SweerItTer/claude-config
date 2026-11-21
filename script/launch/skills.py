"""skills 生命周期：外部（npx skills）、仓库自有（symlink）、已装列表枚举。

外部安装照搬 setup.sh install_external_skills：freshness 比对 → 同名去重 →
repo+scope 分组并行 add（每 worker 独立 XDG_STATE_HOME 写 lock）→ 收尾合并回规范 lock。

自检: cd script && python3 -m launch.skills
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

if __package__ in (None, ""):  # 允许 python3 script/launch/skills.py 直接跑自检
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import launch.util as util
from launch.agents import LOCK_FILE, AgentSpec, resolve_agent
from launch.freshness import check_freshness
from launch.lockmerge import merge_locks
from launch.manifest import SkillSource, load_skills, local_skill_names as manifest_local_names


def _skills_config() -> Path:
    return util.repo_root() / "configs" / "skills.toml"


def _add_args(repo: str, skills: list[str], agent_key: str, scope: str) -> list[str]:
    args = ["npx", "-y", "skills@latest", "add", "-y", repo]
    for skill in skills:
        args += ["-s", skill]
    args += ["-a", agent_key]
    if scope == "global":
        args.append("-g")
    return args


def _dump_log(path: Path, limit: int = 40) -> None:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return
    for line in lines[:limit]:
        print(line)


def _install_group(work: Path, idx: int, repo: str, scope: str,
                   skills: list[str], agent_key: str, names: list[str]) -> tuple[str, bool, Path]:
    """一个并行 worker：同 repo+scope 的多个 skill 合并为一次 add（一次 clone、一次 lock 写入）。

    每个 worker 用独立 XDG_STATE_HOME：npx skills 的全局 lock 是"读-改-写"且无文件锁，
    多个 add 并行写同一 lock 会互相覆盖丢条目（实测 4 个并行只剩 3 条），而丢条目的 skill
    会被下次最新版比对判成"未安装"反复重装。故各写各的 lock，结束后统一合并。

    返回 (标签, 是否成功, worker 目录)。
    """
    wdir = work / f"g{idx}"
    (wdir / "state").mkdir(parents=True)
    args = _add_args(repo, skills, agent_key, scope)
    # add 后必须再传 -y：第一个 -y 是 npx 的（自动确认下载包），add -y 才是 skills CLI 的
    #（跳过 "Proceed with installation?" 交互确认）。缺 add -y 时，非 agent 环境
    #（无 AI_AGENT/CLAUDE_* env 且无 TTY，如 cron/CI/普通 shell）skills CLI 会卡在确认提示
    # 不真正安装。update/remove 已带 -y，仅 add 有此问题。
    # 输出落 log 文件：并行时若直接写 stdout，多个 worker 的进度框会互相撕裂。
    env = dict(os.environ, XDG_STATE_HOME=str(wdir / "state"))
    with open(wdir / "out.log", "wb") as logf:
        proc = subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                              stdout=logf, stderr=logf)
    return " ".join(names), proc.returncode == 0, wdir


def install(sources: list[SkillSource], agent: AgentSpec, *,
            names: list[str] | None = None, force: bool = False) -> int:
    """安装外部 skills。names=[] → 全量。返回失败数（0/1）。

    freshness 比对 → up-to-date 跳过（汇总一行）→ pending 按 repo+scope 分组 →
    并行 add → lock 合并。dry-run 只打印完整 npx 命令，无任何副作用。
    """
    if names:
        wanted = set(names)
        sources = [s for s in sources if s.name in wanted]
    if not sources:
        if names:
            util.info(f"无匹配的外部 skill: {' '.join(names)}")
        return 0

    verdicts = check_freshness(sources, agent.skills_dir, LOCK_FILE, force=force)
    pending: list[SkillSource] = []
    skipped: list[str] = []
    for verdict in verdicts:
        src = verdict.source
        if verdict.verdict == "up-to-date":
            # 幂等跳过合并为一行汇报：逐项一行在重跑时占满屏幕。
            skipped.append(src.name)
            util.info(f"skill '{src.name}' 已安装且为最新版，跳过 (hash {verdict.detail})")
            continue
        if verdict.verdict == "outdated":
            util.info(f"skill '{src.name}' 有新版本，重新安装 ({verdict.detail})")
        elif verdict.verdict == "missing":
            util.info(f"skill '{src.name}' 未安装，开始安装 ({verdict.detail})")
        elif verdict.verdict == "forced":
            util.info(f"skill '{src.name}' --force 指定，强制重装")
        else:
            util.warn(f"skill '{src.name}' 无法比对远端版本（{verdict.detail}），按需安装")
        # 兜底：外部 skill 只装到当前目标 agent 目录。npx skills 不带 -a 时会按已检测到的
        # agent 扩散安装，-a '*' 更是装到所有 agent 目录，因此清单里的 agent 字段只作提示，
        # 实际透传的恒为当前目标的 npx key。
        if agent.key == "claude" and src.agent and src.agent != agent.npx_key:
            util.warn(f"source '{src.name}' 的 agent='{src.agent}' 非 {agent.npx_key}，"
                      f"已按 {agent.npx_key} 安装")
        pending.append(src)

    if skipped:
        util.log(f"已是最新，跳过 {len(skipped)} 个 skill: {' '.join(skipped)}")
    if not pending:
        return 0

    # 同一 skill 名被不同仓库重复声明时只保留首个：remote skill 的 identity 就是真实 skill 名，
    # 同名并发写同一目标目录是数据竞争。wildcard 身份是 source alias，不参与去重。
    claimed = ""
    deduped: list[SkillSource] = []
    for src in pending:
        if src.skill != "*" and f"|{src.skill}|" in claimed:
            util.warn(f"skill '{src.skill}' 已被其它 source 声明，跳过 '{src.name}'"
                      f"（同名并发安装会互相覆盖）")
            continue
        if src.skill != "*":
            claimed += f"|{src.skill}|"
        deduped.append(src)
    if not deduped:
        return 0

    # 分组：repo+scope 相同 → 一次 add（一次 clone、一次 lock 写入），组间并发。
    groups: dict[tuple[str, str], dict] = {}
    for src in deduped:
        group = groups.setdefault((src.repo, src.scope),
                                  {"star": False, "skills": [], "names": []})
        if src.skill == "*":
            group["star"] = True
        elif src.skill not in group["skills"]:
            group["skills"].append(src.skill)
        if src.name not in group["names"]:
            group["names"].append(src.name)

    if util.DRY_RUN:
        for (repo, scope), group in groups.items():
            skills = ["*"] if group["star"] else group["skills"]
            for skill in skills:
                util.dry(" ".join(_add_args(repo, [skill], agent.npx_key, scope)))
            util.dry(f"skill 已安装: {' '.join(group['names'])}")
        return 0

    try:
        jobs = max(1, int(os.environ.get("SKILLS_INSTALL_JOBS", "3")))
    except ValueError:
        jobs = 3

    rc = 0
    work = Path(tempfile.mkdtemp(prefix="launch-skills-"))
    try:
        futures = []
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            for idx, ((repo, scope), group) in enumerate(groups.items(), 1):
                skills = ["*"] if group["star"] else group["skills"]
                futures.append(pool.submit(_install_group, work, idx, repo, scope,
                                           skills, agent.npx_key, group["names"]))
            # 按提交顺序汇报（输出不交错）
            for future in futures:
                try:
                    label, ok, wdir = future.result()
                except Exception as exc:  # worker 崩溃按失败计
                    rc = 1
                    util.err(f"外部 skill 安装失败: {exc}")
                    continue
                if ok:
                    for name in label.split(" "):
                        util.log(f"skill '{name}' 已安装")
                else:
                    rc = 1
                    util.err(f"外部 skill 安装失败: {label}")
                    _dump_log(wdir / "out.log")

        # 把各 worker 的独立 lock 合并回规范 lock（否则丢失的条目会让 skill 反复重装）
        worker_locks = [p for p in sorted(work.glob("g*/state/skills/.skill-lock.json"))
                        if p.is_file()]
        if worker_locks:
            try:
                merge_locks(LOCK_FILE, worker_locks)
            except (OSError, ValueError):
                rc = 1
                util.err(f"合并 skill lock 失败: {LOCK_FILE}")
                util.warn(f"删除该文件后重跑可重建: rm -f {LOCK_FILE}")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return rc


def install_local(names: list[str], agent: AgentSpec) -> int:
    """仓库自有 skill：skills/<n> symlink 到目标 skills 目录。返回失败数。"""
    failed = 0
    root = util.repo_root()
    for name in names:
        src = root / "skills" / name
        if not (src / "SKILL.md").is_file():
            util.err(f"仓库自有 skill 不存在或缺少 SKILL.md: {name}")
            failed = 1
            continue
        if not util.ensure_symlink(src, agent.skills_dir / name, f"repo skill '{name}'"):
            failed = 1
    return failed


def uninstall(names: list[str], agent: AgentSpec) -> int:
    """卸载外部 skills（npx skills remove）。typed skill:/plugin: 消歧在 cli 完成。

    仅仓库自有（不在 skills.toml）的名字静默跳过——由 uninstall_local 负责，
    cli._uninstall_skill 两侧都调，不应因一侧不适用而置失败。
    """
    by_name = {s.name: s for s in load_skills(_skills_config())}
    local_only = set(manifest_local_names(util.repo_root()))
    failed = 0
    for name in names:
        if name in local_only and name not in by_name:
            continue
        src = by_name.get(name)
        if src is None:
            util.err(f"skills.toml 中找不到 skill: {name}")
            failed = 1
            continue
        args = ["npx", "-y", "skills@latest", "remove", name, "-a", agent.npx_key]
        if src.scope == "global":
            args.append("-g")
        args.append("-y")
        util.info(f"卸载 skill: {name}")
        if util.DRY_RUN:
            util.dry(" ".join(args))
            continue
        if subprocess.run(args).returncode != 0:
            util.err(f"卸载 skill '{name}' 失败")
            failed = 1
            continue
        util.log(f"skill '{name}' 已卸载")
    return failed


def uninstall_local(names: list[str], agent: AgentSpec) -> int:
    """移除目标目录下本仓库的 skill symlink。绝不触碰仓库 skills/ 源文件。"""
    failed = 0
    root = util.repo_root()
    for name in names:
        src = root / "skills" / name
        if not util.remove_symlink_if_ours(agent.skills_dir / name,
                                           f"repo skill '{name}'", src):
            failed = 1
    return failed


def update(names: list[str], agent: AgentSpec) -> int:
    """更新指定外部 skills（npx skills update <name> [-g] -y）。"""
    by_name = {s.name: s for s in load_skills(_skills_config())}
    failed = 0
    for name in names:
        src = by_name.get(name)
        if src is None:
            util.err(f"skills.toml 中找不到 skill: {name}")
            failed = 1
            continue
        args = ["npx", "-y", "skills@latest", "update", name]
        if src.scope == "global":
            args.append("-g")
        args.append("-y")
        util.info(f"更新 skill: {name}")
        if util.DRY_RUN:
            util.dry(" ".join(args))
            continue
        if subprocess.run(args).returncode != 0:
            util.err(f"更新 skill '{name}' 失败")
            failed = 1
            continue
        util.log(f"skill '{name}' 已更新")
    return failed


def update_all(agent: AgentSpec) -> int:
    """更新全部外部 skills（无 name 过滤，全局 -g）。"""
    if not _skills_config().is_file():
        util.info("无 skills.toml，跳过外部 skill 更新")
        return 0
    util.info("更新所有外部 skills...")
    args = ["npx", "-y", "skills@latest", "update", "-g", "-y"]
    if util.DRY_RUN:
        util.dry(" ".join(args))
        return 0
    if subprocess.run(args).returncode != 0:
        util.err("更新 skills 失败")
        return 1
    util.log("外部 skills 已更新")
    return 0


@dataclass(frozen=True)
class InstalledSkill:
    dir: Path
    name: str      # frontmatter name 优先，目录名回退
    source: str    # "local" | "npx" | "unknown"
    detail: str    # symlink 目标路径或 repo


def _frontmatter_name(skill_md: Path) -> str | None:
    """SKILL.md 前 40 行内的 frontmatter name: 行。"""
    try:
        with open(skill_md, encoding="utf-8") as fp:
            for idx, line in enumerate(fp):
                if idx >= 40:
                    break
                matched = re.match(r"name:\s*(.+?)\s*$", line)
                if matched:
                    return matched.group(1)
    except OSError:
        return None
    return None


def _lock_skills() -> dict:
    try:
        with open(LOCK_FILE, encoding="utf-8") as fp:
            data = json.load(fp)
    except (OSError, ValueError):
        return {}
    skills = data.get("skills") if isinstance(data, dict) else None
    return skills if isinstance(skills, dict) else {}


def installed(agent: AgentSpec) -> list[InstalledSkill]:
    """枚举目标目录下含 SKILL.md 的 skill，标注来源。

    symlink → (local, 目标路径)；LOCK_FILE 命中 → (npx, repo)；否则 (unknown, "")。
    """
    lock_skills = _lock_skills()
    result: list[InstalledSkill] = []
    skills_dir = agent.skills_dir
    if not skills_dir.is_dir():
        return result
    for entry in sorted(skills_dir.iterdir()):
        skill_md = entry / "SKILL.md"
        if not entry.is_dir() or not skill_md.is_file():
            continue
        name = _frontmatter_name(skill_md) or entry.name
        if entry.is_symlink():
            result.append(InstalledSkill(entry, name, "local", os.path.realpath(entry)))
            continue
        record = lock_skills.get(name) or lock_skills.get(entry.name)
        if isinstance(record, dict):
            repo = record.get("source") or ""
            if not repo:
                url = (record.get("sourceUrl") or "").removesuffix(".git")
                repo = url.removeprefix("https://github.com/")
            result.append(InstalledSkill(entry, name, "npx", repo))
            continue
        result.append(InstalledSkill(entry, name, "unknown", ""))
    return result


if __name__ == "__main__":
    import io
    from contextlib import redirect_stdout
    from tempfile import TemporaryDirectory
    from types import SimpleNamespace

    with TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        root = tmp_path / "repo"
        (root / "configs").mkdir(parents=True)
        (root / "skills" / "demo").mkdir(parents=True)
        (root / "skills" / "demo" / "SKILL.md").write_text(
            "---\nname: demo-skill\n---\n正文\n", encoding="utf-8")
        skills_home = tmp_path / "home" / "skills"
        os.environ["LAUNCH_REPO_ROOT"] = str(root)
        os.environ["AGENTS_SKILLS_HOME"] = str(skills_home)
        os.environ["SKILLS_LOCK_FILE"] = str(tmp_path / "home" / "lock.json")
        agent = resolve_agent("agents")

        # install_local + installed(local)
        assert install_local(["demo"], agent) == 0
        link = skills_home / "demo"
        assert link.is_symlink() and (link / "SKILL.md").is_file()
        found = installed(agent)
        assert len(found) == 1
        assert found[0].name == "demo-skill" and found[0].source == "local"
        assert found[0].detail == str(root / "skills" / "demo")

        # uninstall_local：只删 symlink，仓库 skills/ 源文件不动
        assert uninstall_local(["demo"], agent) == 0
        assert not link.is_symlink() and not link.exists()
        assert (root / "skills" / "demo" / "SKILL.md").is_file()

        # install_local：缺 SKILL.md 报失败
        assert install_local(["nope"], agent) == 1

        # npx 命令形态：add 后必须再传 -y
        args = _add_args("owner/repo", ["a", "b"], "universal", "global")
        assert args[:4] == ["npx", "-y", "skills@latest", "add"] and args[4] == "-y"
        assert args[5:] == ["owner/repo", "-s", "a", "-s", "b", "-a", "universal", "-g"]

        # dry-run install：完整命令行、同名去重、无副作用
        (root / "configs" / "skills.toml").write_text(
            '[[sources]]\nname = "ext-a"\nrepo = "owner/a"\nskill = "a"\n'
            '[[sources]]\nname = "ext-b"\nrepo = "owner/a"\nskill = "b"\n'
            '[[sources]]\nname = "dup"\nrepo = "owner/other"\nskill = "a"\n',
            encoding="utf-8")

        def fake_freshness(srcs, target_dir, lock_file, *, force=False):
            return [SimpleNamespace(source=s, verdict="missing", detail="lock 无安装记录")
                    for s in srcs]

        check_freshness = fake_freshness  # 自检替身，避免真实网络比对
        sources = load_skills(root / "configs" / "skills.toml")
        util.DRY_RUN = True
        buf = io.StringIO()
        with redirect_stdout(buf):
            assert install(sources, agent) == 0
        out = buf.getvalue()
        assert "npx -y skills@latest add -y owner/a -s a -a universal -g" in out
        assert "npx -y skills@latest add -y owner/a -s b -a universal -g" in out
        assert "owner/other" not in out  # 同名 skill 'a' 已被 ext-a 声明，dup 被去重
        assert not Path(os.environ["SKILLS_LOCK_FILE"]).exists()  # dry-run 无副作用

        buf = io.StringIO()
        with redirect_stdout(buf):
            assert install(sources, agent, names=["ext-b"]) == 0
        out = buf.getvalue()
        assert "-s b" in out and "-s a " not in out  # names 过滤只装指定项
        util.DRY_RUN = False

    util.log("launch.skills 自检通过")
