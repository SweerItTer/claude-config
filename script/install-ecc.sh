#!/usr/bin/env bash
# install-ecc.sh — Everything Claude Code 插件安装
# npm install + symlink agents/commands + skills 逐个符号链接 + 自定义 agents 覆盖
set -euo pipefail

install_ecc() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local ecc_dir="$repo_root/external/everything-claude-code"
    local custom_agents="$repo_root/config/claude/agents-custom"
    local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

    # 1. npm install
    if [[ ! -d "$ecc_dir/node_modules" ]]; then
        echo "  [INFO] npm install ECC..."
        [[ "$dry_run" == false ]] && {
            (cd "$ecc_dir" && npm install --no-audit --no-fund --loglevel=error)
        }
        echo "  [OK] ECC node_modules 已安装"
    else
        echo "  [OK] ECC node_modules 已存在"
    fi

    # 2. agents 整目录符号链接
    local agents_dst="$claude_home/agents"
    [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $ecc_dir/agents -> $agents_dst"; }
    [[ "$dry_run" == false ]] && {
        [[ -L "$agents_dst" ]] || [[ -d "$agents_dst" ]] && rm -rf "$agents_dst"
        ln -sfn "$ecc_dir/agents" "$agents_dst"
    }
    echo "  [OK] ECC agents symlinked"

    # 3. 覆盖自定义 agents
    if [[ -d "$custom_agents" ]]; then
        for f in "$custom_agents"/*.md; do
            local name; name="$(basename "$f")"
            [[ "$dry_run" == false ]] && cp "$f" "$agents_dst/$name"
            [[ "$dry_run" == true ]] && echo "  [DRY-RUN] cp $f -> $agents_dst/$name"
        done
        echo "  [OK] 自定义 agents 覆盖完成"
    fi

    # 4. commands 整目录符号链接
    local cmds_dst="$claude_home/commands"
    [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $ecc_dir/commands -> $cmds_dst"; }
    [[ "$dry_run" == false ]] && {
        [[ -L "$cmds_dst" ]] || [[ -d "$cmds_dst" ]] && rm -rf "$cmds_dst"
        ln -sfn "$ecc_dir/commands" "$cmds_dst"
    }
    echo "  [OK] ECC commands symlinked"

    # 5. skills 逐个符号链接
    local skills_src="$ecc_dir/skills"
    local skills_dst="$claude_home/skills"
    mkdir -p "$skills_dst"
    if [[ -d "$skills_src" ]]; then
        for skill_dir in "$skills_src"/*/; do
            local name; name="$(basename "$skill_dir")"
            local dst="$skills_dst/$name"
            [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $skill_dir -> $dst"; continue; }
            [[ -L "$dst" ]] || [[ -d "$dst" ]] && rm -rf "$dst"
            ln -sfn "$skill_dir" "$dst"
        done
    fi
    echo "  [OK] ECC skills symlinked"
}

install_ecc "$@"
