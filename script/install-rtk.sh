#!/usr/bin/env bash
# install-rtk.sh — RTK (Rust Token Killer) 安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"

RTK_VERSION="v0.40.0"
INSTALL_DIR="$HOME/.local/bin"
RTK_BIN="$INSTALL_DIR/rtk"
CFG_SRC="$REPO_ROOT/config/rtk"
CFG_DST="$HOME/.config/rtk"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_HOME/hooks"
HOOK_SCRIPT="$HOOKS_DIR/rtk-rewrite.sh"
HOOK_URL="https://raw.githubusercontent.com/rtk-ai/rtk/master/hooks/claude/rtk-rewrite.sh"

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

settings_have_rtk_hook() {
    grep -q 'rtk-rewrite' "$CLAUDE_HOME/settings.json" 2>/dev/null
}

hook_script_ready() {
    [[ -x "$HOOK_SCRIPT" ]]
}

rtk_bin() {
    if [[ -x "$RTK_BIN" ]]; then
        printf '%s\n' "$RTK_BIN"
    else
        printf '%s\n' rtk
    fi
}

is_ready() {
    command -v "$(rtk_bin)" >/dev/null 2>&1 || return 1
    "$(rtk_bin)" --version >/dev/null 2>&1 || return 1
    symlink_points_to "$CFG_DST/config.toml" "$CFG_SRC/config.toml" || return 1
    symlink_points_to "$CFG_DST/filters.toml" "$CFG_SRC/filters.toml" || return 1
    hook_script_ready || return 1
    settings_have_rtk_hook || return 1
}

download_rtk() {
    local arch tarball url tmpdir bin
    arch="$(uname -m)"
    tarball="rtk-${arch}-unknown-linux-gnu.tar.gz"
    [[ "$arch" == "x86_64" ]] && tarball="rtk-x86_64-unknown-linux-musl.tar.gz"
    url="https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${tarball}"

    tmpdir="$(mktemp -d)"
    curl --fail -sL "$url" -o "$tmpdir/$tarball" || {
        rm -rf "$tmpdir"
        err "下载 RTK 失败: $url"
        return 1
    }
    tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
    bin="$(find "$tmpdir" -name rtk -type f | head -1)"
    [[ -n "$bin" ]] || {
        rm -rf "$tmpdir"
        err "未找到 rtk 二进制"
        return 1
    }

    mkdir -p "$INSTALL_DIR"
    mv "$bin" "$RTK_BIN"
    chmod +x "$RTK_BIN"
    rm -rf "$tmpdir"
    ok "RTK 安装完成: $("$RTK_BIN" --version 2>&1)"
}

link_config() {
    mkdir -p "$CFG_DST"
    for file in config.toml filters.toml; do
        local src="$CFG_SRC/$file"
        local dst="$CFG_DST/$file"
        if symlink_points_to "$dst" "$src"; then
            ok "RTK config 已就绪: $file"
            continue
        fi
        if [[ -L "$dst" || -f "$dst" ]]; then
            rm -f "$dst"
        elif [[ -d "$dst" ]]; then
            rm -rf "$dst"
        fi
        ln -sfn "$src" "$dst"
        ok "RTK config 已更新: $file"
    done
}

run_rtk_init() {
    local bin
    bin="$(rtk_bin)"

    info "执行 rtk init..."
    "$bin" init -g --auto-patch 2>&1 || info "rtk init 返回非零，继续用 verify 判定结果"
}

ensure_hook_script() {
    mkdir -p "$HOOKS_DIR"
    if hook_script_ready; then
        ok "rtk-rewrite.sh 已存在"
        return 0
    fi

    curl --fail -sL "$HOOK_URL" -o "$HOOK_SCRIPT" || {
        err "下载 rtk-rewrite.sh 失败"
        return 1
    }
    chmod +x "$HOOK_SCRIPT"
    ok "rtk-rewrite.sh 已安装"
}

install() {
    if command -v "$(rtk_bin)" >/dev/null 2>&1; then
        ok "RTK 已安装: $("$(rtk_bin)" --version 2>&1)"
    else
        info "下载 RTK ${RTK_VERSION}..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] 下载并安装 $RTK_VERSION 到 $RTK_BIN"
        else
            download_rtk
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $CFG_SRC/config.toml -> $CFG_DST/config.toml"
        info "[DRY-RUN] ln -sfn $CFG_SRC/filters.toml -> $CFG_DST/filters.toml"
        info "[DRY-RUN] rtk init -g --auto-patch"
        info "[DRY-RUN] curl -sL $HOOK_URL -o $HOOK_SCRIPT"
        return 0
    fi

    link_config
    run_rtk_init
    ensure_hook_script
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    { command -v rtk >/dev/null 2>&1 || [[ -x "$RTK_BIN" ]]; } || { err "rtk 命令不存在"; return 1; }
    { rtk --version >/dev/null 2>&1 || "$RTK_BIN" --version >/dev/null 2>&1; } || { err "rtk --version 失败"; return 1; }
    symlink_points_to "$CFG_DST/config.toml" "$CFG_SRC/config.toml" || { err "config.toml symlink 错误"; return 1; }
    symlink_points_to "$CFG_DST/filters.toml" "$CFG_SRC/filters.toml" || { err "filters.toml symlink 错误"; return 1; }
    hook_script_ready || { err "rtk-rewrite.sh 缺失或不可执行"; return 1; }
    settings_have_rtk_hook || { err "settings.json 缺少 rtk hook"; return 1; }

    ok "RTK verify 通过"
}

main() {
    if [[ "$FORCE" == false ]] && is_ready; then
        pass "RTK 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"
