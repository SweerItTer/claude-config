#!/usr/bin/env bash
# install-superpowers.sh — Superpowers 插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"

SUPERPOWERS_DIR="$REPO_ROOT/external/superpowers"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/superpowers"
LEGACY_SKILLS=(
    brainstorming executing-plans finishing-a-development-branch
    receiving-code-review requesting-code-review subagent-driven-development
    systematic-debugging test-driven-development using-git-worktrees
    using-superpowers verification-before-completion writing-plans
    writing-skills dispatching-parallel-agents
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

legacy_skills_cleared() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name
    for name in "${LEGACY_SKILLS[@]}"; do
        [[ -e "$skills_dir/$name" ]] && return 1
    done
    return 0
}

is_ready() {
    symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR" || return 1
    legacy_skills_cleared || return 1
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR"; then
        ok "superpowers marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"
    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi
    ln -sfn "$SUPERPOWERS_DIR" "$MARKETPLACE_DST"
    ok "superpowers marketplace 已注册"
}

cleanup_legacy_skills() {
    local skills_dir="$CLAUDE_HOME/skills"
    local name path
    [[ -d "$skills_dir" ]] || { ok "superpowers legacy skills 无残留"; return 0; }

    for name in "${LEGACY_SKILLS[@]}"; do
        path="$skills_dir/$name"
        [[ -e "$path" ]] || continue
        rm -rf "$path"
        info "清理旧 superpowers skill: $name"
    done
    ok "superpowers legacy skills 已清理"
}

install() {
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $SUPERPOWERS_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] 清理旧 superpowers skills 残留"
        return 0
    fi

    link_marketplace
    cleanup_legacy_skills
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    symlink_points_to "$MARKETPLACE_DST" "$SUPERPOWERS_DIR" || { err "superpowers marketplace 未指向源码目录"; return 1; }
    legacy_skills_cleared || { err "旧 superpowers skills 残留未清理"; return 1; }

    ok "superpowers verify 通过"
}

main() {
    if [[ "$FORCE" == false ]] && is_ready; then
        pass "superpowers 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"
