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

    # 3. 清理旧版 OMC skills 链接，skills 由 plugin marketplace 运行时发现
    local skills_src="$omc_dir/skills"
    local skills_dst="$claude_home/skills"
    local removed_count=0
    if [[ -d "$skills_src" && -d "$skills_dst" ]]; then
        for skill_dir in "$skills_src"/*/; do
            [[ -d "$skill_dir" ]] || continue
            local name; name="$(basename "$skill_dir")"
            local dst="$skills_dst/$name"
            [[ -L "$dst" ]] || continue
            local target; target="$(readlink -f "$dst")"
            [[ "$target" == "$(readlink -f "${skill_dir%/}")" ]] || continue
            [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] rm $dst"; continue; }
            rm -f "$dst"
            removed_count=$((removed_count + 1))
        done
    fi
    echo "  [OK] OMC legacy skills cleaned ($removed_count)"

    # 4. 运行 OMC setup (处理 hooks, HUD, CLAUDE.md 合并)
    # --plugin-dir-mode: 跳过 agent/skill 复制，skills 通过 plugin marketplace 提供
    echo "  [INFO] 运行 omc setup..."
    [[ "$dry_run" == false ]] && {
        cd "$omc_dir"
        node bridge/cli.cjs setup --plugin-dir-mode --quiet 2>&1 || {
            echo "  [WARN] omc setup 有非致命警告，继续..."
        }
    }
    [[ "$dry_run" == true ]] && echo "  [DRY-RUN] node bridge/cli.cjs setup --plugin-dir-mode --quiet"
    echo "  [OK] OMC setup 完成 (hooks, HUD, CLAUDE.md)"

    # 5. 修复插件缓存布局：Claude doctor 期望顶层 commands 目录
    local cache_root="$claude_home/plugins/cache/omc/oh-my-claudecode"
    if [[ -d "$cache_root" ]]; then
        local cache_version
        for cache_version in "$cache_root"/*; do
            [[ -d "$cache_version" ]] || continue
            if [[ ! -e "$cache_version/commands" && -d "$cache_version/dist/commands" ]]; then
                [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn dist/commands -> $cache_version/commands"; continue; }
                ln -sfn dist/commands "$cache_version/commands"
                echo "  [OK] OMC cache commands -> dist/commands ($(basename "$cache_version"))"
            fi
        done
    fi

    # 6. 链接 OMC wiki (自定义内容)
    mkdir -p "$HOME/.omc"

    local wiki_src="$repo_root/config/omc/wiki"
    local wiki_dst="$HOME/.omc/wiki"
    if [[ -d "$wiki_src" ]]; then
        [[ "$dry_run" == true ]] && { echo "  [DRY-RUN] ln -sfn $wiki_src -> $wiki_dst"; }
        [[ "$dry_run" == false ]] && {
            [[ -L "$wiki_dst" ]] || [[ -d "$wiki_dst" ]] && rm -rf "$wiki_dst"
            ln -sfn "$wiki_src" "$wiki_dst"
        }
        echo "  [OK] OMC wiki symlinked"
    fi
}

install_omc "$@"
