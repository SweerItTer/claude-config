#!/usr/bin/env bash
# install-superpowers.sh — Superpowers 插件安装
# 来自 github.com/obra/superpowers，提供 14 个 skills + SessionStart hook
set -euo pipefail

install_superpowers() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local sp_dir="$repo_root/external/superpowers"
    local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local mp_dir="$claude_home/plugins/marketplaces"

    # 1. marketplace 符号链接
    local dst="$mp_dir/superpowers"
    [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $sp_dir -> $dst"; }
    [[ "$dry_run" == false ]] && {
        mkdir -p "$mp_dir"
        [[ -L "$dst" ]] || [[ -d "$dst" ]] && rm -rf "$dst"
        ln -sfn "$sp_dir" "$dst"
    }
    echo "  [OK] superpowers marketplace 已注册"

    # 2. 清理旧版 cp -r 残留的 skills (迁移)
    local skills_dir="$claude_home/skills"
    local old_skills=(
        brainstorming executing-plans finishing-a-development-branch
        receiving-code-review requesting-code-review subagent-driven-development
        systematic-debugging test-driven-development using-git-worktrees
        using-superpowers verification-before-completion writing-plans
        writing-skills dispatching-parallel-agents
    )
    if [[ -d "$skills_dir" ]]; then
        for name in "${old_skills[@]}"; do
            local sp="$skills_dir/$name"
            if [[ -d "$sp" ]] && [[ ! -L "$sp" ]]; then
                echo "  [INFO] 清理旧 superpowers skill: $name"
                [[ "$dry_run" == false ]] && rm -rf "$sp"
            fi
        done
    fi
}

install_superpowers "$@"
