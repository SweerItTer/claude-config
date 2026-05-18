#!/usr/bin/env bash
# install-omc.sh — OMC (oh-my-claudecode) 插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"

OMC_DIR="$REPO_ROOT/external/oh-my-claudecode"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/omc"
WIKI_SRC="$REPO_ROOT/config/omc/wiki"
WIKI_DST="$HOME/.omc/wiki"

LEGACY_SKILLS=(
    omc-reference omc-setup omc-doctor ai-slop-cleaner autodoc autopilot autoresearch
    cancel ccg configure-notifications context-mode ctx-doctor ctx-insight ctx-purge
    ctx-stats ctx-upgrade debug deep-dive deep-interview external-context hud learner
    mcp-setup omc-teams omc-reference omc-setup plan project-session-manager ralph ralplan
    release remember sciomc self-improve setup skill skillify team trace ultraqa ultrawork verify
    visual-verdict wiki writer-memory
)

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
err()  { echo "  [ERR] $*"; }

symlink_points_to() {
    local link="$1"
    local target="$2"

    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

omc_injected() {
    grep -q 'OMC:START' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null
}

legacy_skills_cleared() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name

    for name in "${LEGACY_SKILLS[@]}"; do
        [[ -e "$skills_dir/$name" ]] && return 1
    done

    return 0
}

wiki_ready() {
    [[ ! -d "$WIKI_SRC" ]] && return 0
    symlink_points_to "$WIKI_DST" "$WIKI_SRC"
}

is_ready() {
    [[ -d "$OMC_DIR" ]] || return 1
    [[ -d "$OMC_DIR/node_modules" ]] || return 1
    symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR" || return 1
    omc_injected || return 1
    legacy_skills_cleared || return 1
    wiki_ready || return 1
    return 0
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR"; then
        ok "OMC marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"

    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi

    ln -sfn "$OMC_DIR" "$MARKETPLACE_DST"
    ok "OMC marketplace 已注册"
}

cleanup_legacy_skills() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name
    local path

    [[ -d "$skills_dir" ]] || {
        ok "OMC legacy skills 无残留"
        return 0
    }

    for name in "${LEGACY_SKILLS[@]}"; do
        path="$skills_dir/$name"
        [[ -e "$path" ]] || continue
        rm -rf "$path"
        info "清理旧 OMC skill: $name"
    done

    ok "OMC legacy skills 已清理"
}

run_bridge_setup() {
    info "运行 omc setup..."
    (
        cd "$OMC_DIR"
        node bridge/cli.cjs setup --plugin-dir-mode --quiet 2>&1 || info "omc setup 返回非零，继续用 verify 判定结果"
    )
    ok "OMC setup 已执行"
}

link_wiki() {
    [[ -d "$WIKI_SRC" ]] || {
        info "OMC wiki 源目录不存在，跳过"
        return 0
    }

    if symlink_points_to "$WIKI_DST" "$WIKI_SRC"; then
        ok "OMC wiki 已就绪"
        return 0
    fi

    mkdir -p "$(dirname "$WIKI_DST")"

    if [[ -L "$WIKI_DST" || -f "$WIKI_DST" ]]; then
        rm -f "$WIKI_DST"
    elif [[ -d "$WIKI_DST" ]]; then
        rm -rf "$WIKI_DST"
    fi

    ln -sfn "$WIKI_SRC" "$WIKI_DST"
    ok "OMC wiki 已链接"
}

install() {
    [[ -d "$OMC_DIR" ]] || {
        err "OMC 源目录不存在: $OMC_DIR"
        return 1
    }

    if [[ ! -d "$OMC_DIR/node_modules" ]]; then
        info "npm install OMC..."
        if [[ true == "$DRY_RUN" ]]; then
            info "[DRY-RUN] (cd $OMC_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$OMC_DIR"
                npm install --no-audit --no-fund --loglevel=error
            )
            ok "OMC node_modules 已安装"
        fi
    else
        ok "OMC node_modules 已存在"
    fi

    if [[ true == "$DRY_RUN" ]]; then
        info "[DRY-RUN] ln -sfn $OMC_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] 清理旧 OMC skills 残留"
        info "[DRY-RUN] node bridge/cli.cjs setup --plugin-dir-mode --quiet"
        info "[DRY-RUN] ln -sfn $WIKI_SRC -> $WIKI_DST"
        return 0
    fi

    link_marketplace
    cleanup_legacy_skills
    run_bridge_setup
    link_wiki
}

verify() {
    if [[ true == "$DRY_RUN" ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    [[ -d "$OMC_DIR" ]] || {
        err "OMC 源目录不存在: $OMC_DIR"
        return 1
    }

    [[ -d "$OMC_DIR/node_modules" ]] || {
        err "OMC node_modules 不存在"
        return 1
    }

    symlink_points_to "$MARKETPLACE_DST" "$OMC_DIR" || {
        err "OMC marketplace 未指向源码目录"
        return 1
    }

    omc_injected || {
        err "CLAUDE.md 未注入 OMC 内容"
        return 1
    }

    legacy_skills_cleared || {
        err "旧 OMC skills 残留未清理"
        return 1
    }

    wiki_ready || {
        err "OMC wiki symlink 不正确"
        return 1
    }

    ok "OMC verify 通过"
}

main() {
    if [[ false == "$FORCE" ]] && is_ready; then
        pass "OMC 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"