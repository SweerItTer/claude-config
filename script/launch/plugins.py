"""第三方 plugins 生命周期（claude plugin marketplace）。

method=claude-plugin 走 `claude plugin marketplace add` + `claude plugin install -s user`；
method=npx 只提示手动命令。uninstall/update 对称。

自检: cd script && python3 -m launch.plugins
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ""):  # 允许 python3 script/launch/plugins.py 直接跑自检
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import launch.util as util
from launch.manifest import PluginSource, load_plugins


def _plugins_config() -> Path:
    return util.repo_root() / "configs" / "plugins.toml"


def _filtered(names: list[str] | None) -> list[PluginSource]:
    sources = load_plugins(_plugins_config())
    if not names:
        return sources
    wanted = set(names)
    return [s for s in sources if s.name in wanted]


def _run(args: list[str]) -> bool:
    return subprocess.run(args).returncode == 0


def install(names: list[str] | None = None) -> int:
    """安装第三方 plugins。names=[] → plugins.toml 全部。"""
    sources = _filtered(names)
    if names and not sources:
        util.info(f"无匹配的 plugin: {' '.join(names)}")
        return 0
    for src in sources:
        if src.method == "claude-plugin":
            if util.DRY_RUN:
                util.dry(f"安装 plugin: {src.name} (marketplace: {src.marketplace})")
                util.dry(f"claude plugin marketplace add {src.repo} --scope user"
                         f" && claude plugin install {src.name}@{src.marketplace} -s user")
                util.dry(f"plugin '{src.name}' 已安装")
                continue
            util.info(f"安装 plugin: {src.name} (marketplace: {src.marketplace})")
            if subprocess.run(["claude", "plugin", "marketplace", "add", src.repo,
                               "--scope", "user"],
                              stderr=subprocess.DEVNULL).returncode != 0:
                util.warn(f"marketplace 添加失败（可能已存在）: {src.name}")
            if not _run(["claude", "plugin", "install",
                         f"{src.name}@{src.marketplace}", "-s", "user"]):
                util.err(f"安装 plugin '{src.name}' 失败")
                return 1
            util.log(f"plugin '{src.name}' 已安装")
        elif src.method == "npx":
            util.warn(f"需手动安装 plugin '{src.name}': {src.command}")
        else:
            util.warn(f"未知安装方式 '{src.method}'，跳过 plugin '{src.name}'")
    return 0


def uninstall(names: list[str]) -> int:
    by_name = {s.name: s for s in load_plugins(_plugins_config())}
    failed = 0
    for name in names:
        src = by_name.get(name)
        if src is None:
            util.err(f"plugins.toml 中找不到 plugin: {name}")
            failed = 1
            continue
        if src.method == "npx":
            util.warn(f"plugin '{name}' 是 npx 手动安装，需手动卸载: {src.command}")
            continue
        util.info(f"卸载 plugin: {name}")
        if util.DRY_RUN:
            util.dry(f"claude plugin uninstall {src.name}@{src.marketplace} -s user -y")
            continue
        if not _run(["claude", "plugin", "uninstall",
                     f"{src.name}@{src.marketplace}", "-s", "user", "-y"]):
            util.err(f"卸载 plugin '{name}' 失败")
            failed = 1
            continue
        util.log(f"plugin '{name}' 已卸载")
    return failed


def update(names: list[str] | None = None) -> int:
    """更新第三方 plugins。names=[] → 全部；任一项失败最终非零。"""
    sources = _filtered(names)
    if names and not sources:
        util.err(f"无匹配的 plugin: {' '.join(names)}")
        return 1
    failed = 0
    for src in sources:
        if src.method == "npx":
            util.warn(f"plugin '{src.name}' 是 npx 手动安装，需手动更新: {src.command}")
            continue
        util.info(f"更新 plugin: {src.name}")
        if util.DRY_RUN:
            util.dry(f"claude plugin update {src.name}@{src.marketplace} -s user")
            continue
        if not _run(["claude", "plugin", "update",
                     f"{src.name}@{src.marketplace}", "-s", "user"]):
            util.err(f"更新 plugin '{src.name}' 失败")
            failed = 1
    return failed


def _parse_plugin_list(text: str) -> dict[str, bool]:
    """claude plugin list --json 输出 → {plugin_id: 以 user scope 注册}。"""
    try:
        items = json.loads(text)
    except ValueError:
        return {}
    result: dict[str, bool] = {}
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                result[item["id"]] = item.get("scope") == "user"
    return result


def registered() -> dict[str, bool]:
    """claude plugin list --json → {id: bool}。读取失败 → {}。"""
    proc = subprocess.run(["claude", "plugin", "list", "--json"],
                          capture_output=True, text=True, errors="replace")
    if proc.returncode != 0:
        util.err("读取 claude plugin list --json 失败")
        for line in proc.stderr.splitlines()[:30]:
            print(line, file=sys.stderr)
        return {}
    return _parse_plugin_list(proc.stdout)


if __name__ == "__main__":
    import io
    import os
    from contextlib import redirect_stderr, redirect_stdout
    from tempfile import TemporaryDirectory

    with TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        root = tmp_path / "repo"
        (root / "configs").mkdir(parents=True)
        (root / "configs" / "plugins.toml").write_text(
            '[[plugins]]\nname = "good"\nrepo = "owner/mkt"\nmethod = "claude-plugin"\n'
            'marketplace = "mkt"\n'
            '[[plugins]]\nname = "manual"\nrepo = "owner/x"\nmethod = "npx"\n'
            'command = "npx thing install"\n',
            encoding="utf-8")
        os.environ["LAUNCH_REPO_ROOT"] = str(root)
        util.DRY_RUN = True

        buf = io.StringIO()
        with redirect_stdout(buf):
            assert install() == 0
        out = buf.getvalue()
        assert "claude plugin marketplace add owner/mkt --scope user" in out
        assert "claude plugin install good@mkt -s user" in out
        assert "需手动安装 plugin 'manual': npx thing install" in out

        buf = io.StringIO()
        with redirect_stdout(buf):
            assert install(["good"]) == 0
        assert "manual" not in buf.getvalue()  # names 过滤

        buf = io.StringIO()
        with redirect_stdout(buf):
            assert uninstall(["good"]) == 0
        assert "claude plugin uninstall good@mkt -s user -y" in buf.getvalue()

        buf = io.StringIO()
        with redirect_stdout(buf):
            assert update(["good", "manual"]) == 0
        out = buf.getvalue()
        assert "claude plugin update good@mkt -s user" in out
        assert "需手动更新" in out

        buf_err = io.StringIO()
        with redirect_stdout(buf), redirect_stderr(buf_err):
            assert uninstall(["ghost"]) == 1  # 清单中找不到
        assert "plugins.toml 中找不到 plugin: ghost" in buf_err.getvalue()

        # JSON 解析（scope=user 才算注册）
        assert _parse_plugin_list(
            '[{"id": "a@m", "scope": "user"}, {"id": "b@m", "scope": "project"}]'
        ) == {"a@m": True, "b@m": False}
        assert _parse_plugin_list("not json") == {}
        util.DRY_RUN = False

    util.log("launch.plugins 自检通过")
