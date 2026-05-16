#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
omc_cli="$repo_root/external/oh-my-claudecode/bridge/cli.cjs"
timeout_seconds="${CLAUDE_DOCTOR_TIMEOUT:-120}"

if [[ ! -f "$omc_cli" ]]; then
    echo "FAIL: OMC CLI 不存在: $omc_cli"
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
    if grep -q 'No unified MCP registry found' "$tmp" && ! grep -Eq 'Missing from Claude MCP config|Missing from Codex config.toml|Registry exists but has no MCP servers' "$tmp"; then
        echo "WARN: OMC doctor conflicts 返回 $rc；可选 MCP registry 未配置，不阻断基础迁移"
    else
        echo "FAIL: OMC doctor conflicts 返回 $rc，插件/配置诊断未通过"
        exit "$rc"
    fi
fi

echo "OK: OMC doctor 核心插件迁移诊断通过"
