#!/usr/bin/env bash
# Tests for script/launch/tui.py — launch --tui curses UI.
# Bash wrapper: module assert self-check + pty smoke (script -qec, start & quit)
# + non-TTY branch (stderr 中文报错, exit 2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 -m py_compile "$REPO_ROOT/script/launch/tui.py" \
    || { echo "FAIL: compileall tui"; exit 1; }

# 模块自带 __main__ assert 自检（数据拉取 + 键位 dispatch + fake stdscr 冒烟）
python3 "$REPO_ROOT/script/launch/tui.py" \
    || { echo "FAIL: tui 自检失败"; exit 1; }

command -v script >/dev/null || { echo "SKIP: 无 script 命令，跳过 pty 冒烟"; exit 0; }

# --- pty 冒烟：能启动、'q' 能退出（timeout 3 兜底；不追求键位覆盖）---
# timeout 默认在新进程组跑子进程，会与 pty 会话竞争输入 → 必须 --foreground。
if printf 'q' | script -qec "timeout --foreground 3 $REPO_ROOT/launch --tui" /dev/null; then
    :
else
    rc=$?
    # timeout 124 = 程序启动后没退出；其余非零 = TUI 崩溃
    if [ "$rc" -eq 124 ]; then
        echo "FAIL: --tui 未在 3s 内响应 q 退出"
        exit 1
    fi
    echo "FAIL: pty 冒烟 --tui 退出码 $rc"
    exit 1
fi

# --- 非 TTY 分支：stderr 中文报错 + exit 2（不经 timeout 即失败）---
out="$(mktemp)"; err="$(mktemp)"
"$REPO_ROOT/launch" --tui --no-color < /dev/null > "$out" 2> "$err" \
    && { echo "FAIL: 非 TTY 应退出 2"; exit 1; } || rc=$?
if [ "$rc" -ne 2 ]; then
    echo "FAIL: 非 TTY 退出码应为 2, 实际 $rc"
    exit 1
fi
grep -q "终端" "$err" || { echo "FAIL: stderr 缺中文报错: $(cat "$err")"; exit 1; }
rm -f "$out" "$err"

echo "test-launch-tui passed."
