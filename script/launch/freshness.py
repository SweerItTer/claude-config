#!/usr/bin/env python3
"""skill 最新版比对：lock hash vs 远端 GitHub tree oid。

吸收自 script/check-skill-freshness.py，stdin/stdout TSV 改为函数调用：
check_freshness(sources, target_dir, lock_file, *, force=False) -> list[FreshVerdict]。

判定口径与 npx skills 的 `update` 检查一致：全局 lock（.skill-lock.json）记录
skill 的安装来源与 skillFolderHash（GitHub tree oid）。取远端仓库 tree 中该 skill
目录的 sha 与 lock 比对：相等 = 最新（调用方跳过安装）；不等 = 需重装。

未安装的判定：lock 无该记录 / 来源与清单不符 / 目标目录缺 SKILL.md。
比对不了的场景（非 GitHub 源、lock 缺 hash、远端不可达或限流、远端已无该目录）
一律 unknown —— 调用方按"无法比对"处理并照常安装，绝不因为查不到就误跳过。

环境变量：
  SKILLS_API_BASE   GitHub API 基址，默认 https://api.github.com
  GITHUB_TOKEN / GH_TOKEN  可选 token（提高 GitHub API 限流额度）
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

if __package__ in (None, ""):  # 直接执行自检：script/ 加入 sys.path 以支持相对导入
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "launch"

from .manifest import SkillSource

DEFAULT_API_BASE = "https://api.github.com"
DEFAULT_BRANCHES = ("HEAD", "main", "master")
REQUEST_TIMEOUT = 15


@dataclass(frozen=True)
class FreshVerdict:
    source: SkillSource
    verdict: str  # up-to-date | outdated | missing | unknown | forced
    detail: str


def github_token() -> str | None:
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or None


class TreeFetcher:
    """按 (repo, ref) 缓存远端 tree，避免同仓库多 skill 重复请求。"""

    def __init__(self, api_base: str) -> None:
        self.api_base = api_base.rstrip("/")
        self._cache: dict[tuple[str, str], dict | None] = {}

    def tree(self, repo: str, ref: str | None) -> dict | None:
        key = (repo, ref or "")
        if key not in self._cache:
            self._cache[key] = self._fetch(repo, ref)
        return self._cache[key]

    def _fetch(self, repo: str, ref: str | None) -> dict | None:
        for candidate in (ref,) if ref else DEFAULT_BRANCHES:
            url = f"{self.api_base}/repos/{repo}/git/trees/{candidate}?recursive=1"
            request = urllib.request.Request(url)
            request.add_header("Accept", "application/vnd.github+json")
            request.add_header("User-Agent", "claude-config-setup")
            token = github_token()
            if token:
                request.add_header("Authorization", f"Bearer {token}")
            try:
                with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                    payload = json.load(response)
            except urllib.error.HTTPError as exc:
                if exc.code in (403, 429):
                    raise RuntimeError(f"GitHub API 限流 (HTTP {exc.code})") from exc
                continue
            except (urllib.error.URLError, OSError, ValueError) as exc:
                raise RuntimeError(f"远端查询失败: {exc}") from exc
            if isinstance(payload, dict) and isinstance(payload.get("tree"), list):
                return payload
        return None


def skill_folder_hash(tree: dict, skill_path: str) -> str | None:
    """复刻 npx skills 的 getSkillFolderHashFromTree：技能目录的 tree oid。"""
    folder = skill_path.replace("\\", "/")
    lowered = folder.lower()
    if lowered.endswith("/skill.md"):
        folder = folder[: -len("/skill.md")]
    elif lowered.endswith("skill.md"):
        folder = folder[: -len("skill.md")]
    folder = folder.rstrip("/")
    if not folder:
        return tree.get("sha")
    for entry in tree.get("tree") or []:
        if entry.get("type") == "tree" and entry.get("path") == folder:
            return entry.get("sha")
    return None


def source_matches(entry: dict, repo: str) -> bool:
    source = entry.get("source") or ""
    source_url = (entry.get("sourceUrl") or "").removesuffix(".git")
    return source == repo or source_url == "https://github.com/" + repo.removesuffix(".git")


def read_lock(path: Path) -> dict:
    """读 lock 的 skills 字段；文件缺失/损坏 → {}。"""
    try:
        with open(path, encoding="utf-8") as fp:
            lock = json.load(fp)
    except (OSError, ValueError):
        return {}
    skills = lock.get("skills")
    return skills if isinstance(skills, dict) else {}


def installed_dir(target_dir: Path, name: str) -> bool:
    return os.path.isfile(os.path.join(str(target_dir), name, "SKILL.md"))


def decide(name: str, repo: str, target_dir: Path, lock_skills: dict,
           fetcher: TreeFetcher) -> tuple[str, str]:
    entry = lock_skills.get(name)
    if not isinstance(entry, dict):
        return "missing", "lock 无安装记录"
    if not source_matches(entry, repo):
        return "missing", f"已装来源不同 ({(entry.get('source') or entry.get('sourceUrl') or 'unknown')})"
    if not installed_dir(target_dir, name):
        return "missing", f"{target_dir}/{name} 缺 SKILL.md"

    if entry.get("sourceType") != "github":
        return "unknown", f"非 GitHub 源 ({entry.get('sourceType')})，无法比对远端版本"
    skill_path = entry.get("skillPath") or ""
    recorded = entry.get("skillFolderHash") or ""
    if not skill_path or not recorded:
        return "unknown", "lock 缺 skillPath/skillFolderHash，无法比对远端版本"

    ref = entry.get("ref") or None
    try:
        tree = fetcher.tree(repo, ref)
    except RuntimeError as exc:
        return "unknown", str(exc)
    if tree is None:
        return "unknown", "远端仓库不可达"

    latest = skill_folder_hash(tree, skill_path)
    if not latest:
        return "unknown", f"远端已无该 skill 目录 ({skill_path})"
    if latest == recorded:
        return "up-to-date", f"{recorded[:12]}"
    return "outdated", f"远端 {latest[:12]} ≠ 已装 {recorded[:12]}"


def check_freshness(sources: list[SkillSource], target_dir: Path, lock_file: Path, *,
                    force: bool = False) -> list[FreshVerdict]:
    """逐个 source 产出安装决定。force=True 时全部 forced（跳过比对与网络）。"""
    api_base = os.environ.get("SKILLS_API_BASE") or DEFAULT_API_BASE
    lock_skills = {} if force else read_lock(lock_file)
    fetcher = TreeFetcher(api_base)

    verdicts: list[FreshVerdict] = []
    for src in sources:
        if force:
            status, detail = "forced", "--force 跳过比对"
        else:
            status, detail = decide(src.name, src.repo, target_dir, lock_skills, fetcher)
        verdicts.append(FreshVerdict(source=src, verdict=status, detail=detail))
    return verdicts


if __name__ == "__main__":
    # --- 自检：mock lock + 断网环境（SKILLS_API_BASE 指向不可达端口）---
    with __import__("tempfile").TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        target = tmp_path / "skills"
        (target / "grilling").mkdir(parents=True)
        (target / "grilling" / "SKILL.md").write_text("---\nname: grilling\n---\n", encoding="utf-8")

        lock = tmp_path / "lock.json"
        lock.write_text(__import__("json").dumps({
            "version": 3,
            "skills": {
                "grilling": {
                    "source": "mattpocock/skills", "sourceType": "github",
                    "skillPath": "skills/productivity/grilling",
                    "skillFolderHash": "abc123def4567890", "ref": "HEAD",
                },
                "ghost": {
                    "source": "other/repo", "sourceType": "github",
                    "skillPath": "x", "skillFolderHash": "ff",
                },
                "humanizer": {
                    "source": "blader/humanizer", "sourceType": "github",
                    "skillPath": "humanizer", "skillFolderHash": "deadbeefcafe0000",
                },
                "non-github": {
                    "source": "gitlab.com/x/y", "sourceType": "gitlab",
                    "skillPath": "x", "skillFolderHash": "aa",
                },
                "no-hash": {"source": "o/r", "sourceType": "github"},
            },
        }), encoding="utf-8")
        # humanizer 有 lock 记录且目录存在（比对走远端，不可达 → unknown）
        (target / "humanizer").mkdir()
        (target / "humanizer" / "SKILL.md").write_text(
            "---\nname: humanizer\n---\n", encoding="utf-8")
        # non-github / no-hash：目录存在才能走到各自的 unknown 分支
        (target / "non-github").mkdir()
        (target / "non-github" / "SKILL.md").write_text("x", encoding="utf-8")
        (target / "no-hash").mkdir()
        (target / "no-hash" / "SKILL.md").write_text("x", encoding="utf-8")

        def src(name, repo):
            return SkillSource(name=name, repo=repo, skill=name)

        # 1) 远端不可达 → up-to-date 判定退化为 unknown（但 lock 命中且目录在）
        os.environ["SKILLS_API_BASE"] = "http://127.0.0.1:1"
        verdicts = check_freshness(
            [src("grilling", "mattpocock/skills"), src("ghost", "other/repo"),
             src("humanizer", "blader/humanizer"), src("non-github", "gitlab.com/x/y"),
             src("no-hash", "o/r"), src("never-installed", "o/r2")],
            target, lock)
        by_name = {v.source.name: v.verdict for v in verdicts}
        assert by_name["grilling"] == "unknown", by_name  # 远端不可达
        assert by_name["ghost"] == "missing", by_name  # lock 有记录但目标目录缺 SKILL.md
        assert by_name["humanizer"] == "unknown"  # 远端不可达
        assert by_name["non-github"] == "unknown"  # 非 GitHub 源
        assert by_name["no-hash"] == "unknown"  # lock 缺 hash
        assert by_name["never-installed"] == "missing"  # lock 无记录
        details = {v.source.name: v.detail for v in verdicts}
        assert details["grilling"].startswith("远端查询失败")  # 连接被拒
        assert "缺 SKILL.md" in details["ghost"]

        # 来源不匹配：lock 记录的 source ≠ 清单 repo → missing
        verdicts = check_freshness([src("grilling", "someone/else")], target, lock)
        assert verdicts[0].verdict == "missing" and "已装来源不同" in verdicts[0].detail

        # 2) force=True → 全部 forced，不发任何网络请求
        verdicts = check_freshness(
            [src("grilling", "mattpocock/skills")], target, lock, force=True)
        assert len(verdicts) == 1 and verdicts[0].verdict == "forced"

        # 3) lock 文件缺失 → 全部 missing
        verdicts = check_freshness(
            [src("grilling", "mattpocock/skills")], target, tmp_path / "no-lock.json")
        assert verdicts[0].verdict == "missing" and "lock 无安装记录" in verdicts[0].detail

        # 4) skill_folder_hash 单元：目录 oid / 根 / skill.md 后缀剥离
        tree = {"sha": "rootsha", "tree": [
            {"type": "tree", "path": "skills/productivity/grilling", "sha": "foldsha"},
            {"type": "blob", "path": "skills/productivity/grilling/SKILL.md", "sha": "x"},
        ]}
        assert skill_folder_hash(tree, "skills/productivity/grilling") == "foldsha"
        assert skill_folder_hash(tree, "skills/productivity/grilling/SKILL.md") == "foldsha"
        assert skill_folder_hash(tree, "") == "rootsha"
        assert skill_folder_hash(tree, "no-such-dir") is None

    print("freshness self-check passed.")
