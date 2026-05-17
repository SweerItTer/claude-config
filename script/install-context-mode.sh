#!/usr/bin/env bash
# install-context-mode.sh — 上下文窗口管理插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"

CTX_DIR="$REPO_ROOT/external/context-mode"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/context-mode"
CACHE_ROOT="$CLAUDE_HOME/plugins/cache/context-mode/context-mode"

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

latest_cache_version() {
    [[ -d "$CACHE_ROOT" ]] || return 1

    local latest_name

    latest_name="$(
        find "$CACHE_ROOT" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            ! -name current \
            -printf '%f\n' |
	grep -E '^(dev-.+|v?[0-9]+(\.[0-9]+)*(-[0-9]+-g[0-9a-f]+)?)$' |
        sort -V |
        tail -n 1
    )"

    [[ -n "$latest_name" ]] || return 1

    printf '%s\n' "$CACHE_ROOT/$latest_name"
}

current_link_ready() {
    local latest
    latest="$(latest_cache_version)" || return 1
    [[ -L "$CACHE_ROOT/current" ]] || return 1
    [[ "$(readlink -f "$CACHE_ROOT/current")" == "$(readlink -f "$latest")" ]]
}

is_ready() {
    [[ -d "$CTX_DIR/node_modules" ]] || return 1
    symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || return 1

    if latest_cache_version >/dev/null 2>&1; then
        current_link_ready || return 1
    fi

    return 0
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        ok "context-mode marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"
    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi
    ln -sfn "$CTX_DIR" "$MARKETPLACE_DST"
    ok "context-mode marketplace 已注册"
}

link_current_cache() {
    local latest
    local tag

    if ! latest="$(latest_cache_version)"; then
        info "context-mode cache 尚未生成版本目录，创建 cache 目录"

        tag="$(git -C "$CTX_DIR" describe --tags 2>/dev/null)" || true
        if [[ -z "$tag" ]]; then
            tag="dev-$(git -C "$CTX_DIR" rev-parse --short HEAD 2>/dev/null || date +%s)"
        fi

        mkdir -p "$CACHE_ROOT" || return 1

        cp -a "$CTX_DIR" "$CACHE_ROOT/$tag" || return 1

        latest="$(latest_cache_version)" || {
            info "context-mode cache 创建后仍然无法找到版本目录"
            return 1
        }
    fi

    if current_link_ready; then
        ok "context-mode current 已指向最新缓存"
        return 0
    fi

    ln -sfn "$latest" "$CACHE_ROOT/current"
    ok "context-mode current 已更新 -> $(basename "$latest")"
}

install() {
    if [[ ! -d "$CTX_DIR/node_modules" ]]; then
        info "npm install context-mode..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] (cd $CTX_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$CTX_DIR"
                npm install --no-audit --no-fund --loglevel=error
            )
            ok "context-mode node_modules 已安装"
        fi
    else
        ok "context-mode node_modules 已存在"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $CTX_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] 根据缓存情况维护 $CACHE_ROOT/current"
        return 0
    fi

    link_marketplace
    link_current_cache
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    [[ -d "$CTX_DIR/node_modules" ]] || { err "context-mode node_modules 不存在"; return 1; }
    symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || { err "context-mode marketplace 未指向源码目录"; return 1; }

    if latest_cache_version >/dev/null 2>&1; then
        current_link_ready || { err "context-mode current 未指向最新缓存"; return 1; }
    else
        info "context-mode cache 尚未生成版本目录，verify 跳过 current 检查"
    fi

    ok "context-mode verify 通过"
}

main() {
    if [[ "$FORCE" == false ]] && is_ready; then
        pass "context-mode 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"
