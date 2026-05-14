#!/usr/bin/env bash
# install-context-mode.sh — 上下文窗口管理插件安装
# npm install (含 native better-sqlite3) + marketplace 注册
set -euo pipefail

install_context_mode() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local ctx_dir="$repo_root/external/context-mode"
    local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local mp_dir="$claude_home/plugins/marketplaces"

    # 1. npm install (需要 better-sqlite3 原生依赖)
    if [[ ! -d "$ctx_dir/node_modules" ]]; then
        echo "  [INFO] npm install context-mode..."
        [[ "$dry_run" == false ]] && {
            (cd "$ctx_dir" && npm install --no-audit --no-fund --loglevel=error)
        }
        echo "  [OK] context-mode node_modules 已安装"
    else
        echo "  [OK] context-mode node_modules 已存在"
    fi

    # 2. marketplace 符号链接
    local dst="$mp_dir/context-mode"
    [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $ctx_dir -> $dst"; }
    [[ "$dry_run" == false ]] && {
        mkdir -p "$mp_dir"
        [[ -L "$dst" ]] || [[ -d "$dst" ]] && rm -rf "$dst"
        ln -sfn "$ctx_dir" "$dst"
    }
    echo "  [OK] context-mode marketplace 已注册"
}

install_context_mode "$@"
