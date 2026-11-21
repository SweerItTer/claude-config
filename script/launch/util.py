#!/usr/bin/env python3
"""launch 基础层：日志/颜色/全局开关/confirm/symlink 操作/依赖检测。

语义照搬 setup.sh 顶部：
- NO_COLOR 置位或 stdout 非 TTY → 颜色为空串（模块加载时判定一次）。
- info 默认静默，VERBOSE=True 或消息含 "[DRY-RUN]" 时打印；dry 恒打印。
- confirm：CI_MODE/DRY_RUN/YES/非 TTY(stdin) → True；否则 input Y/n（空=确认）。
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 颜色：模块加载时判定（NO_COLOR 或非 TTY → 空串），与 setup.sh 顶部一致
# ---------------------------------------------------------------------------
if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
    RED = GREEN = YELLOW = BLUE = NC = ""
else:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    BLUE = "\033[0;34m"
    NC = "\033[0m"

# ---------------------------------------------------------------------------
# 全局开关（cli 稍后设置；默认 False）
# ---------------------------------------------------------------------------
VERBOSE: bool = False
DRY_RUN: bool = False
CI_MODE: bool = False
YES: bool = False
FORCE: bool = False


def repo_root() -> Path:
    """仓库根：script/launch/x.py → parents[2]；LAUNCH_REPO_ROOT 可覆盖（测试用）。"""
    override = os.environ.get("LAUNCH_REPO_ROOT")
    if override:
        return Path(override).resolve()
    return Path(__file__).resolve().parents[2]


def log(msg: str) -> None:
    print(f"{GREEN}✔ {msg}{NC}")


def warn(msg: str) -> None:
    print(f"{YELLOW}▲ {msg}{NC}")


def err(msg: str) -> None:
    print(f"{RED}✖ {msg}{NC}", file=sys.stderr)


def info(msg: str) -> None:
    # info 默认静默（-v 恢复），但 [DRY-RUN] 前缀的行恒打印：预览必须可信，
    # 不能被 VERBOSE 静默（语义照搬 setup.sh info()）。
    if VERBOSE or "[DRY-RUN]" in msg:
        print(f"{BLUE}• {msg}{NC}")


def phase(msg: str) -> None:
    print(f"\n{BLUE}▸ {msg}{NC}")


def dry(msg: str) -> None:
    # dry-run 分支的打印点恒打印（预览必须可信，不能被 VERBOSE 静默）。
    print(f"{BLUE}[dry-run] {msg}{NC}")


def confirm(prompt: str) -> bool:
    """CI/dry-run/YES/非TTY(stdin) → True；否则 input Y/n（空=确认）。"""
    if CI_MODE or DRY_RUN or YES or not sys.stdin.isatty():
        return True
    try:
        reply = input(f"{prompt} [Y/n] ")
    except EOFError:
        return True
    return reply.strip().lower() in ("", "y", "yes")


# ---------------------------------------------------------------------------
# symlink 操作（照搬 setup.sh ensure_symlink / remove_symlink_if_ours）
# ---------------------------------------------------------------------------

def _symlink_points_to(link: Path, target: Path) -> bool:
    """link 是指向 target（resolve 后同一路径）的符号链接。"""
    if not link.is_symlink() or not target.exists():
        return False
    return os.path.realpath(link) == os.path.realpath(target)


def ensure_symlink(src: Path, dst: Path, label: str) -> bool:
    """幂等确保 dst 是指向 src 的符号链接。False=失败（err 已打印）。

    已有目录且非 symlink → 需 FORCE，否则 err+False（避免删除用户维护内容）。
    dry-run 分支只打印 would 行为，无副作用，恒返回 True。
    """
    if _symlink_points_to(dst, src):
        log(f"{label} 已就绪")
        return True

    if DRY_RUN:
        if dst.is_dir() and not dst.is_symlink() and not FORCE:
            dry(f"would fail: {label} 目标是已有目录，需 --force 才能替换 ({dst})")
        elif dst.exists() or dst.is_symlink():
            dry(f"replace {dst} with symlink to {src}")
        else:
            dry(f"ln -s {src} -> {dst}")
        return True

    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink() or dst.is_file():
        dst.unlink()
    elif dst.is_dir():
        if not FORCE:
            err(f"{label} 目标已存在且是目录: {dst}。为避免删除用户维护内容，请先手动处理或使用 --force。")
            warn("先手动处理该路径，或加 --force 强制替换")
            return False
        shutil.rmtree(dst)
    elif dst.exists():
        err(f"{label} 目标已存在且类型不受支持: {dst}")
        warn("先手动处理该路径，或加 --force 强制替换")
        return False
    dst.symlink_to(src)
    log(f"{label} 已更新")
    return True


def remove_symlink_if_ours(path: Path, label: str, expected_src: Path) -> bool:
    """仅当 path 是指向 expected_src 的符号链接才删除；其余情况不动。恒 True（删除失败除外）。

    dry-run 只打印。
    """
    if not path.is_symlink():
        if path.exists():
            info(f"跳过非符号链接: {label} ({path})")
        return True

    current = os.path.realpath(path)
    if current != os.path.realpath(expected_src):
        warn(f"符号链接目标不匹配，跳过: {label} ({path} -> {current}, 期望 {expected_src})")
        return True

    if DRY_RUN:
        dry(f"rm {path}")
        return True

    try:
        path.unlink()
    except OSError as exc:
        err(f"移除失败: {label} ({path}): {exc}")
        return False
    log(f"已移除: {label}")
    return True


# ---------------------------------------------------------------------------
# 依赖检测：只检测+提示，绝不自动安装（R9：砍掉 sudo/nvm 自动安装）
# ---------------------------------------------------------------------------
_REQUIRED_TOOLS = ("git", "curl", "tar", "python3", "node", "npm")
MIN_NODE_MAJOR = 20
MAX_NODE_MAJOR = 25


def check_dependencies() -> list[str]:
    """返回缺失的可执行名列表；node 主版本须在 20–25 区间，否则视作缺失。

    缺失时 err 输出中文提示 + 手动安装命令（按包管理器一行提示）。
    """
    missing = [t for t in _REQUIRED_TOOLS if not shutil.which(t)]

    # node 版本区间检查（20–25）：有 node 但版本不兼容 → 按缺失 node 处理
    if "node" not in missing:
        try:
            out = __import__("subprocess").run(
                ["node", "-p", "process.versions.node.split('.')[0]"],
                capture_output=True, text=True, timeout=15, check=True,
            ).stdout.strip()
            major = int(out)
            if not (MIN_NODE_MAJOR <= major <= MAX_NODE_MAJOR):
                warn(f"当前 Node.js 主版本 {major} 超出兼容范围（支持 {MIN_NODE_MAJOR}–{MAX_NODE_MAJOR}），请升级后再试")
                missing.append("node")
        except (subprocess_error(), ValueError, OSError):
            warn("无法识别当前 Node.js 版本，请确认 node 可用")
            missing.append("node")

    if missing:
        err(f"缺少依赖: {' '.join(missing)}，请手动安装后重试")
        if shutil.which("apt-get"):
            info(f"可手动执行: sudo apt-get update && sudo apt-get install -y {' '.join(missing)}")
        elif shutil.which("dnf"):
            info(f"可手动执行: sudo dnf install -y {' '.join(missing)}")
        elif shutil.which("brew"):
            info(f"可手动执行: brew install {' '.join(missing)}")
        else:
            info(f"请手动安装后重试: {' '.join(missing)}")
        if "node" in missing or "npm" in missing:
            info("node/npm 建议按 Node.js 官方下载页的推荐脚本方式安装最新版（nvm install --lts）")
    else:
        log("git, curl, tar, node, npm, python3 已就绪")
    return missing


def subprocess_error():
    """局部导入，避免顶部冗余 import（只在 check_dependencies 里用一次）。"""
    import subprocess
    return subprocess.SubprocessError


if __name__ == "__main__":
    # --- 自检 ---
    # 日志函数语义：VERBOSE=False 时 info 不打印（除非含 [DRY-RUN]）
    assert not VERBOSE and not DRY_RUN
    # 颜色在非 TTY（pytest/管道）下为空串
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        assert RED == ""
    # confirm 直通规则
    YES = True
    assert confirm("x") is True
    YES = False
    DRY_RUN = True
    assert confirm("x") is True
    DRY_RUN = False
    CI_MODE = True
    assert confirm("x") is True
    CI_MODE = False

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "src"
        src.mkdir()
        src.joinpath("f.txt").write_text("x", encoding="utf-8")
        dst = root / "dst"

        # ensure_symlink：新建 / 幂等 / 替换已有链接 / 目录保护 / dry-run
        assert ensure_symlink(src, dst, "t1") is True and dst.is_symlink()
        assert ensure_symlink(src, dst, "t2") is True  # 幂等
        other = root / "other"
        other.symlink_to(src.parent)
        assert ensure_symlink(src, other, "t3") is True  # 替换已有链接
        assert os.path.realpath(other) == os.path.realpath(src)
        dstdir = root / "dstdir"
        dstdir.mkdir()
        FORCE = False
        assert ensure_symlink(src, dstdir, "t4") is False  # 目录保护
        FORCE = True
        assert ensure_symlink(src, dstdir, "t5") is True  # --force 替换
        FORCE = False
        DRY_RUN = True
        missing_dir = root / "notyet"
        assert ensure_symlink(src, missing_dir, "t6") is True  # dry-run 无副作用
        assert not missing_dir.exists()
        DRY_RUN = False

        # remove_symlink_if_ours：删自己的 / 跳过别人的 / 跳过普通文件 / dry-run
        assert remove_symlink_if_ours(dst, "r1", src) is True and not dst.exists()
        unrelated = root / "unrelated-dir"
        unrelated.mkdir()
        rogue = root / "rogue"
        rogue.symlink_to(unrelated)
        assert remove_symlink_if_ours(rogue, "r2", src) is True and rogue.is_symlink()
        plain = root / "plain"
        plain.write_text("x", encoding="utf-8")
        assert remove_symlink_if_ours(plain, "r3", src) is True and plain.exists()
        dst.symlink_to(src)
        DRY_RUN = True
        assert remove_symlink_if_ours(dst, "r4", src) is True and dst.is_symlink()
        DRY_RUN = False
        assert remove_symlink_if_ours(dst, "r5", src) is True and not dst.exists()

    # repo_root()
    import os as _os
    _os.environ.pop("LAUNCH_REPO_ROOT", None)
    assert repo_root() == Path(__file__).resolve().parents[2]
    _os.environ["LAUNCH_REPO_ROOT"] = "/tmp"
    assert repo_root() == Path("/tmp")
    _os.environ.pop("LAUNCH_REPO_ROOT", None)

    # check_dependencies：本机应无缺失（CI/开发机都预装 git/node）
    missing = check_dependencies()
    assert isinstance(missing, list)

    print("util self-check passed.")
