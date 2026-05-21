#!/usr/bin/env bash
# install-context-mode.sh — 上下文窗口管理插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
NO_PATCH="${4:-false}"

CTX_DIR="$REPO_ROOT/external/context-mode"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/context-mode"

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

symlink_points_to() {
    local link="$1"
    local target="$2"

    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

is_ready() {
    [[ -d "$CTX_DIR" ]] || return 1
    [[ -d "$CTX_DIR/node_modules" ]] || return 1
    symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || return 1
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

apply_routing_patch() {
    local patch_file="$REPO_ROOT/config/context-mode/strict-bash-routing.patch"

    if [[ "$NO_PATCH" == true ]]; then
        info "跳过 routing.mjs 补丁 (--no-patch)"
        return 0
    fi

    [[ -f "$patch_file" ]] || {
        warn "补丁文件不存在: $patch_file"
        return 0
    }

    # 检查是否已打过补丁
    if grep -q "CTX_STRICT_BASH" "$CTX_DIR/hooks/core/routing.mjs" 2>/dev/null; then
        ok "routing.mjs 补丁已应用"
        return 0
    fi

    info "应用 routing.mjs strict-bash 补丁..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] git -C $CTX_DIR apply $patch_file"
        return 0
    fi

    if git -C "$CTX_DIR" apply --check "$patch_file" 2>/dev/null; then
        git -C "$CTX_DIR" apply "$patch_file"
        ok "routing.mjs 补丁已应用 (git apply)"
    elif patch -p1 -d "$CTX_DIR" --dry-run --silent < "$patch_file" 2>/dev/null; then
        patch -p1 -d "$CTX_DIR" --silent < "$patch_file"
        ok "routing.mjs 补丁已应用 (patch)"
    else
        err "routing.mjs 补丁应用失败，请检查补丁与源码是否匹配"
        return 1
    fi
}

install() {
    [[ -d "$CTX_DIR" ]] || {
        err "context-mode 源目录不存在: $CTX_DIR"
        return 1
    }

    if [[ ! -d "$CTX_DIR/node_modules" ]]; then
        info "npm install context-mode..."
        if [[ true == "$DRY_RUN" ]]; then
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

    apply_routing_patch

    if [[ true == "$DRY_RUN" ]]; then
        info "[DRY-RUN] ln -sfn $CTX_DIR -> $MARKETPLACE_DST"
        return 0
    fi

    link_marketplace
}

verify() {
    if [[ true == "$DRY_RUN" ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    [[ -d "$CTX_DIR" ]] || {
        err "context-mode 源目录不存在: $CTX_DIR"
        return 1
    }

    [[ -d "$CTX_DIR/node_modules" ]] || {
        err "context-mode node_modules 不存在"
        return 1
    }

    symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || {
        err "context-mode marketplace 未指向源码目录"
        return 1
    }

    ok "context-mode verify 通过"
}

main() {
    if [[ false == "$FORCE" ]] && is_ready; then
        pass "context-mode 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"