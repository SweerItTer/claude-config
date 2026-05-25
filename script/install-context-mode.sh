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
CTX_INSTALL_MODE="${CTX_INSTALL_MODE:-auto}"
SOURCE_REV_FILE=".source-rev"

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

validate_install_mode() {
    case "$CTX_INSTALL_MODE" in
        auto|symlink|copy) return 0 ;;
        *)
            err "CTX_INSTALL_MODE 仅支持 auto、symlink 或 copy，当前值: $CTX_INSTALL_MODE"
            return 1
            ;;
    esac
}

symlink_points_to() {
    local link="$1"
    local target="$2"

    [[ -L "$link" ]] || return 1
    [[ -e "$target" ]] || return 1
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]
}

source_rev_path() {
    printf '%s/%s\n' "$MARKETPLACE_DST" "$SOURCE_REV_FILE"
}

get_source_rev() {
    git -C "$CTX_DIR" rev-parse HEAD 2>/dev/null || {
        err "无法读取 context-mode 源 revision: $CTX_DIR"
        return 1
    }
}

routing_patch_applied() {
    grep -q "CTX_STRICT_BASH" "$MARKETPLACE_DST/hooks/core/routing.mjs" 2>/dev/null
}

copy_is_fresh() {
    local expected_rev
    local actual_rev
    local rev_file

    rev_file="$(source_rev_path)"
    [[ -f "$rev_file" ]] || return 1

    expected_rev="$(get_source_rev)" || return 1
    actual_rev="$(tr -d '[:space:]' < "$rev_file")"

    [[ -n "$actual_rev" ]] || return 1
    [[ "$actual_rev" == "$expected_rev" ]]
}

is_ready() {
    [[ -d "$CTX_DIR" ]] || return 1
    [[ -d "$CTX_DIR/node_modules" ]] || return 1
    [[ -d "$MARKETPLACE_DST" ]] || return 1
    routing_patch_applied || return 1

    if [[ "$CTX_INSTALL_MODE" == "symlink" ]]; then
        symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || return 1
        return 0
    fi

    if [[ "$CTX_INSTALL_MODE" == "auto" ]] && symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        return 0
    fi

    [[ ! -L "$MARKETPLACE_DST" ]] || return 1
    [[ -d "$MARKETPLACE_DST/node_modules" ]] || return 1
    copy_is_fresh || return 1
    return 0
}

reset_marketplace_dst() {
    mkdir -p "$(dirname "$MARKETPLACE_DST")"

    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        ok "context-mode marketplace 已注册 (symlink)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=symlink] ln -sfn $CTX_DIR -> $MARKETPLACE_DST"
        return 0
    fi

    reset_marketplace_dst || return 1
    ln -sfn "$CTX_DIR" "$MARKETPLACE_DST" || return 1
    ok "context-mode marketplace 已注册 (symlink)"
}

write_source_rev() {
    local rev_file
    local source_rev

    rev_file="$(source_rev_path)"
    source_rev="$(get_source_rev)" || return 1
    printf '%s\n' "$source_rev" > "$rev_file"
}

copy_marketplace() {
    if [[ -d "$MARKETPLACE_DST" ]] && [[ ! -L "$MARKETPLACE_DST" ]] && copy_is_fresh; then
        ok "context-mode marketplace 已复制且为最新副本"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=copy] rm -rf $MARKETPLACE_DST"
        info "[DRY-RUN][mode=copy] mkdir -p $MARKETPLACE_DST"
        info "[DRY-RUN][mode=copy] cp -a $CTX_DIR/. $MARKETPLACE_DST/"
        info "[DRY-RUN][mode=copy] write $(source_rev_path)"
        return 0
    fi

    reset_marketplace_dst || return 1
    mkdir -p "$MARKETPLACE_DST" || return 1
    cp -a "$CTX_DIR/." "$MARKETPLACE_DST/" || return 1
    write_source_rev || return 1
    ok "context-mode marketplace 已复制"
}

active_install_mode() {
    if [[ "$CTX_INSTALL_MODE" != "auto" ]]; then
        printf '%s\n' "$CTX_INSTALL_MODE"
        return 0
    fi

    if symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR"; then
        printf 'symlink\n'
        return 0
    fi

    printf 'copy\n'
}

install_marketplace() {
    if [[ "$CTX_INSTALL_MODE" == "copy" ]]; then
        copy_marketplace
        return 0
    fi

    link_marketplace
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

    if routing_patch_applied; then
        ok "routing.mjs 补丁已应用"
        return 0
    fi

    info "应用 routing.mjs strict-bash 补丁到最终安装目标 ($CTX_INSTALL_MODE)..."

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN][mode=$CTX_INSTALL_MODE] git -C $MARKETPLACE_DST apply $patch_file"
        return 0
    fi

    [[ -d "$MARKETPLACE_DST" ]] || {
        err "context-mode 安装目标不存在: $MARKETPLACE_DST"
        return 1
    }

    if git -C "$MARKETPLACE_DST" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git -C "$MARKETPLACE_DST" apply --check "$patch_file" 2>/dev/null; then
        git -C "$MARKETPLACE_DST" apply "$patch_file"
        ok "routing.mjs 补丁已应用 (git apply)"
    elif patch -p1 -d "$MARKETPLACE_DST" --dry-run --silent < "$patch_file" 2>/dev/null; then
        patch -p1 -d "$MARKETPLACE_DST" --silent < "$patch_file"
        ok "routing.mjs 补丁已应用 (patch)"
    else
        err "routing.mjs 补丁应用失败，请检查补丁与源码是否匹配"
        return 1
    fi
}

install() {
    validate_install_mode || return 1

    if [[ true == "$DRY_RUN" && ! -d "$CTX_DIR" ]]; then
        info "[DRY-RUN] assume prepared source exists: $CTX_DIR"
    elif [[ ! -d "$CTX_DIR" ]]; then
        err "context-mode 源目录不存在: $CTX_DIR"
        return 1
    fi

    info "context-mode 安装模式: $CTX_INSTALL_MODE"

    if [[ ! -d "$CTX_DIR/node_modules" ]]; then
        info "npm install context-mode..."
        if [[ true == "$DRY_RUN" ]]; then
            info "[DRY-RUN][mode=$CTX_INSTALL_MODE] (cd $CTX_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$CTX_DIR"
                npm install --no-audit --no-fund --loglevel=error
            ) || return 1
            ok "context-mode node_modules 已安装"
        fi
    else
        ok "context-mode node_modules 已存在"
    fi

    install_marketplace
    apply_routing_patch
}

verify() {
    local mode

    if [[ true == "$DRY_RUN" ]]; then
        info "dry-run 模式跳过 verify (mode=$CTX_INSTALL_MODE)"
        return 0
    fi

    validate_install_mode || return 1
    mode="$(active_install_mode)"

    [[ -d "$CTX_DIR" ]] || {
        err "context-mode 源目录不存在: $CTX_DIR"
        return 1
    }

    [[ -d "$CTX_DIR/node_modules" ]] || {
        err "context-mode node_modules 不存在"
        return 1
    }

    if [[ "$mode" == "symlink" ]]; then
        symlink_points_to "$MARKETPLACE_DST" "$CTX_DIR" || {
            err "context-mode marketplace 未指向源码目录"
            return 1
        }
    else
        [[ -d "$MARKETPLACE_DST" ]] || {
            err "context-mode marketplace 副本不存在"
            return 1
        }

        [[ ! -L "$MARKETPLACE_DST" ]] || {
            err "context-mode marketplace 当前是 symlink，非 copy 副本"
            return 1
        }

        [[ -d "$MARKETPLACE_DST/node_modules" ]] || {
            err "context-mode marketplace 副本缺少 node_modules"
            return 1
        }

        copy_is_fresh || {
            err "context-mode marketplace 副本不是最新，请重新安装以刷新 .source-rev"
            return 1
        }
    fi

    routing_patch_applied || {
        err "routing.mjs strict-bash 补丁未应用到最终安装目标"
        return 1
    }

    ok "context-mode verify 通过 ($mode)"
}

main() {
    validate_install_mode || return 1

    if [[ false == "$FORCE" ]] && is_ready; then
        pass "context-mode 已就绪，跳过 ($(active_install_mode))"
        verify
        return 0
    fi

    if [[ "$CTX_INSTALL_MODE" == "auto" ]]; then
        CTX_INSTALL_MODE=symlink
        if install && verify; then
            return 0
        fi

        warn "context-mode symlink 安装失败，自动切换为 copy 模式"
        CTX_INSTALL_MODE=copy
        install
        verify
        return 0
    fi

    install
    verify
}

main "$@"
