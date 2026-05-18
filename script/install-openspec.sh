#!/usr/bin/env bash
# install-openspec.sh — OpenSpec CLI 安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
err()  { echo "  [ERR] $*"; }

is_ready() {
    command -v openspec >/dev/null 2>&1 || return 1
    openspec --version >/dev/null 2>&1 || return 1
}

install() {
    info "按官方方式安装 OpenSpec..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] npm install -g @fission-ai/openspec@latest"
        return 0
    fi

    npm install -g @fission-ai/openspec@latest
    cd ~ && openspec init --tools claude && cd -
    ok "OpenSpec 安装完成: $(openspec --version 2>&1 | head -1)"
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    command -v openspec >/dev/null 2>&1 || { err "openspec 命令不存在"; return 1; }
    openspec --version >/dev/null 2>&1 || { err "openspec --version 失败"; return 1; }
    ok "OpenSpec verify 通过"
}

main() {
    if [[ "$FORCE" == false ]] && is_ready; then
        pass "OpenSpec 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"
