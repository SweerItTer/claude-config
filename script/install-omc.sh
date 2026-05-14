#!/usr/bin/env bash
# install-omc.sh — OMC (oh-my-claudecode) 插件安装
# npm install + OMC setup (hooks, HUD, CLAUDE.md merge, MCP registry)
set -euo pipefail

install_omc() {
    local repo_root="${1:?需要 REPO_ROOT}"
    local dry_run="${2:-false}"

    local omc_dir="$repo_root/external/oh-my-claudecode"
    local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local mp_dir="$claude_home/plugins/marketplaces"

    # 1. npm install
    if [[ ! -d "$omc_dir/node_modules" ]]; then
        echo "  [INFO] npm install OMC..."
        [[ "$dry_run" == false ]] && {
            (cd "$omc_dir" && npm install --no-audit --no-fund --loglevel=error)
        }
        echo "  [OK] OMC node_modules 已安装"
    else
        echo "  [OK] OMC node_modules 已存在"
    fi

    # 2. marketplace 符号链接
    local dst="$mp_dir/omc"
    [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $omc_dir -> $dst"; }
    [[ "$dry_run" == false ]] && {
        mkdir -p "$mp_dir"
        [[ -L "$dst" ]] || [[ -d "$dst" ]] && rm -rf "$dst"
        ln -sfn "$omc_dir" "$dst"
    }
    echo "  [OK] OMC marketplace 已注册"

    # 3. 运行 OMC setup (处理 hooks, HUD, CLAUDE.md 合并, MCP registry)
    # --plugin-dir-mode: 跳过 agent/skill 复制 (由 plugin 系统发现), 仍处理 hooks + HUD + CLAUDE.md
    echo "  [INFO] 运行 omc setup..."
    [[ "$dry_run" == false ]] && {
        cd "$omc_dir"
        node bridge/cli.cjs setup --plugin-dir-mode --quiet 2>&1 || {
            echo "  [WARN] omc setup 有非致命警告，继续..."
        }
    }
    [[ "$dry_run" == true ]] && echo "  [DRY-RUN] node bridge/cli.cjs setup --plugin-dir-mode --quiet"
    echo "  [OK] OMC setup 完成 (hooks, HUD, CLAUDE.md)"

    # 4. 链接 wiki (自定义内容)
    local wiki_src="$repo_root/config/omc/wiki"
    local wiki_dst="$HOME/.omc/wiki"
    if [[ -d "$wiki_src" ]]; then
        [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $wiki_src -> $wiki_dst"; }
        [[ "$dry_run" == false ]] && {
            mkdir -p "$HOME/.omc"
            [[ -L "$wiki_dst" ]] || [[ -d "$wiki_dst" ]] && rm -rf "$wiki_dst"
            ln -sfn "$wiki_src" "$wiki_dst"
        }
        echo "  [OK] OMC wiki symlinked"
    fi
}

install_omc "$@"
