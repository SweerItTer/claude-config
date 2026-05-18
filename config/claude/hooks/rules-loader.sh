#!/usr/bin/env bash
# rules-loader.sh — 文件类型感知的规则加载提醒
# PreToolUse hook on Edit/Write: 检测编辑文件类型，提醒读取对应规则
# 每种文件类型每会话仅提醒一次，避免重复噪音。

set -euo pipefail
input="$(cat)"

file_path="$(echo "$input" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ti = d.get('tool_input', {})
print(ti.get('file_path', '') or ti.get('path', '') or '')
" 2>/dev/null)"

echo "$input"

[[ -n "$file_path" ]] || exit 0

ext="${file_path##*.}"
case "$ext" in
    java) hint="java" ;;
    cpp|c|h|hpp) hint="ecc/cpp/ + ecc/c/" ;;
    vue|html) hint="web" ;;
    js|jsx) hint="typescript + web" ;;
    *) exit 0 ;;
esac

# 每种文件类型每会话仅提醒一次
tagfile="/tmp/rules-loader-${ext}"
[[ -f "$tagfile" ]] && exit 0
touch "$tagfile"

echo "[rules-loader] 检测到 .${ext} 文件 — 读取 rules-available/README.md 确定规则集" >&2
