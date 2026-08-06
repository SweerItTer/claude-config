#!/usr/bin/env bash
set -euo pipefail

# OMC CLI 现在由 claude plugin 安装（plugins.toml 的 oh-my-claudecode 条目）。
# 解析已安装的 plugin 缓存路径；找不到则报 FAIL。
claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
timeout_seconds="${CLAUDE_DOCTOR_TIMEOUT:-120}"

omc_cli="$(find "$claude_home/plugins/cache/omc/oh-my-claudecode" -mindepth 3 -maxdepth 3 -path '*/bridge/cli.cjs' -type f 2>/dev/null | sort -V | tail -1 || true)"

if [[ -z "$omc_cli" ]]; then
    echo "FAIL: OMC plugin 未安装 (cache/omc/oh-my-claudecode 下无 bridge/cli.cjs)。请先运行 ./setup.sh 安装 plugin。"
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

set +e
timeout "$timeout_seconds" node "$omc_cli" doctor conflicts >"$tmp" 2>&1
rc=$?
set -e

cat "$tmp"

if [[ $rc -eq 124 ]]; then
    echo "FAIL: OMC doctor conflicts 超时 (${timeout_seconds}s)"
    exit 1
fi

if grep -Eiq 'Path not found|Cannot find module|MODULE_NOT_FOUND|ENOENT' "$tmp"; then
    echo "FAIL: OMC doctor 发现插件安装路径或模块缺失"
    exit 1
fi

if ! grep -q 'Oh-My-ClaudeCode Conflict Diagnostic' "$tmp"; then
    echo "FAIL: OMC doctor 未输出预期诊断报告"
    exit 1
fi

if grep -q 'Skills colliding with plugin skill names' "$tmp"; then
    echo "FAIL: OMC doctor 发现 legacy skills shadow plugin skills"
    exit 1
fi

if [[ $rc -ne 0 ]]; then
    if grep -q 'Potential conflicts detected' "$tmp" \
        && ! grep -Eq '✗|FAIL|Skills colliding with plugin skill names|Path not found|Cannot find module|MODULE_NOT_FOUND|ENOENT' "$tmp"; then
        echo "WARN: OMC doctor 仅报告潜在冲突，无具体阻断项"
        echo "OK: OMC doctor 核心插件迁移诊断通过"
        exit 0
    fi

    if grep -q 'No unified MCP registry found' "$tmp" && ! grep -Eq 'Missing from Claude MCP config|Missing from Codex config.toml|Registry exists but has no MCP servers' "$tmp"; then
        echo "WARN: OMC doctor conflicts 返回 $rc；可选 MCP registry 未配置，不阻断基础迁移"
    else
        echo "FAIL: OMC doctor conflicts 返回 $rc，插件/配置诊断未通过"
        exit "$rc"
    fi
fi

echo "OK: OMC doctor 核心插件迁移诊断通过"
