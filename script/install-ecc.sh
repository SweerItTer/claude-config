#!/usr/bin/env bash
# install-ecc.sh — Everything Claude Code 插件安装
# 官方 install.sh + 自定义 agents 覆盖
set -euo pipefail

install_ecc() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local ecc_dir="$repo_root/external/everything-claude-code"
    local custom_agents="$repo_root/config/claude/agents-custom"
    local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local install_state="$claude_home/ecc/install-state.json"

    if [[ ! -d "$ecc_dir/node_modules" ]]; then
        echo "  [INFO] npm install ECC..."
        [[ "$dry_run" == false ]] && (
            cd "$ecc_dir" && npm install --no-audit --no-fund --loglevel=error
        )
        echo "  [OK] ECC node_modules 已安装"
    else
        echo "  [OK] ECC node_modules 已存在"
    fi

    if [[ "$dry_run" == true ]]; then
        echo "  [DRY-RUN] cd $ecc_dir && ./install.sh --profile full --target claude"
    else
        echo "  [INFO] 运行 ECC 官方安装器..."
        (cd "$ecc_dir" && ./install.sh --profile full --target claude)
        echo "  [OK] ECC 官方安装完成"
    fi

    if [[ -d "$custom_agents" ]]; then
        local agents_dst="$claude_home/agents"
        if [[ "$dry_run" == true ]]; then
            shopt -s nullglob
            for f in "$custom_agents"/*.md; do
                local name
                name="$(basename "$f")"
                echo "  [DRY-RUN] cp $f -> $agents_dst/$name"
            done
            shopt -u nullglob
        else
            mkdir -p "$agents_dst"
            shopt -s nullglob
            for f in "$custom_agents"/*.md; do
                local name
                name="$(basename "$f")"
                cp "$f" "$agents_dst/$name"
            done
            shopt -u nullglob
            echo "  [OK] 自定义 agents 覆盖完成"
        fi
    fi

    if [[ "$dry_run" == false ]]; then
        [[ -f "$install_state" ]] || {
            echo "  [ERR] ECC install-state 不存在: $install_state"
            exit 1
        }
    fi
}

install_ecc "$@"
