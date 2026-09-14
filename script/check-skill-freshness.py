#!/usr/bin/env python3
"""比对已安装 skill 与远端最新版，产出逐项安装决定（TSV）。

stdin   parse-manifests.py skills 的 TSV：name\trepo\tskill\tagent\tscope\tnote
stdout  逐行决定：name\trepo\tskill\tagent\tscope\tstatus\tdetail
        status ∈ up-to-date | outdated | missing | unknown | forced

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

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_API_BASE = "https://api.github.com"
DEFAULT_BRANCHES = ("HEAD", "main", "master")
REQUEST_TIMEOUT = 15


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


def read_lock(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fp:
            lock = json.load(fp)
    except (OSError, ValueError):
        return {}
    skills = lock.get("skills")
    return skills if isinstance(skills, dict) else {}


def installed_dir(target_dir: str, name: str) -> bool:
    return os.path.isfile(os.path.join(target_dir, name, "SKILL.md"))


def decide(
    name: str,
    repo: str,
    target_dir: str,
    lock_skills: dict,
    fetcher: TreeFetcher,
) -> tuple[str, str]:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="skill 最新版比对，输出安装决定 TSV")
    parser.add_argument("--target-dir", required=True, help="skills 安装目录（如 ~/.agents/skills）")
    parser.add_argument("--lock-file", required=True, help="npx skills 全局 lock 路径")
    parser.add_argument("--force", action="store_true", help="跳过比对，全部按需安装")
    parser.add_argument("names", nargs="*", help="只处理这些 skill 名（缺省 = 全部）")
    args = parser.parse_args()

    api_base = os.environ.get("SKILLS_API_BASE") or DEFAULT_API_BASE
    fetcher = TreeFetcher(api_base)
    lock_skills = {} if args.force else read_lock(args.lock_file)
    filters = set(args.names)

    for raw in sys.stdin:
        fields = raw.rstrip("\n").split("\t")
        if len(fields) < 5 or not fields[0]:
            continue
        name, repo, skill, agent, scope = fields[:5]
        if filters and name not in filters:
            continue
        if args.force:
            status, detail = "forced", "--force 跳过比对"
        else:
            status, detail = decide(name, repo, args.target_dir, lock_skills, fetcher)
        print("\t".join([name, repo, skill, agent, scope, status, detail]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
