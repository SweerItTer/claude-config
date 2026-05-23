#!/usr/bin/env bash
# install-codegraph.sh — CodeGraph 安装与验证
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
REFRESH="${4:-false}"

CODEGRAPH_INSTALLER_URL="https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh"
CODEGRAPH_NPM_PACKAGE="@colbymchenry/codegraph@latest"
CODEGRAPH_UPSTREAM_COMMAND="curl -fsSL ${CODEGRAPH_INSTALLER_URL} | sh"
CODEGRAPH_FALLBACK_COMMAND="npm i -g ${CODEGRAPH_NPM_PACKAGE}"

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

print_recovery_guidance() {
    info "可手动重试官方安装器: $CODEGRAPH_UPSTREAM_COMMAND"
    info "若官方安装器失败且 npm 可用，可改用 fallback: $CODEGRAPH_FALLBACK_COMMAND"
}

require_supported_platform() {
    case "$(uname -s)" in
        Linux|Darwin) return 0 ;;
        *)
            err "CodeGraph 安装仅支持 Linux/macOS；当前系统: $(uname -s)"
            print_recovery_guidance
            return 1
            ;;
    esac
}

codegraph_ready() {
    command -v codegraph >/dev/null 2>&1 || return 1
    codegraph --version >/dev/null 2>&1
}

install_with_upstream() {
    info "优先使用 CodeGraph 官方安装器..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $CODEGRAPH_UPSTREAM_COMMAND"
        info "[DRY-RUN] 若官方安装器失败且 npm 可用，将执行 fallback: $CODEGRAPH_FALLBACK_COMMAND"
        return 0
    fi

    if curl -fsSL "$CODEGRAPH_INSTALLER_URL" | sh; then
        ok "CodeGraph 官方安装器执行完成"
        return 0
    fi

    return 1
}

install_with_npm_fallback() {
    command -v npm >/dev/null 2>&1 || {
        err "CodeGraph 官方安装器失败，且 npm 不可用，无法执行 fallback"
        print_recovery_guidance
        return 1
    }

    warn "CodeGraph 官方安装器失败，尝试 npm fallback..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $CODEGRAPH_FALLBACK_COMMAND"
        info "[DRY-RUN] 若需恢复官方安装路径，可在网络恢复后重新运行: $CODEGRAPH_UPSTREAM_COMMAND"
        return 0
    fi

    npm i -g "$CODEGRAPH_NPM_PACKAGE"
    ok "CodeGraph 已通过 npm fallback 安装"
    info "如需恢复到官方安装路径，请在网络恢复后重新运行: $CODEGRAPH_UPSTREAM_COMMAND"
}

install() {
    require_supported_platform

    if install_with_upstream; then
        return 0
    fi

    install_with_npm_fallback
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    if ! command -v codegraph >/dev/null 2>&1; then
        err "CodeGraph verify 失败: 未找到 codegraph 命令"
        print_recovery_guidance
        return 1
    fi

    local version_output
    if ! version_output="$(codegraph --version 2>&1)"; then
        err "CodeGraph verify 失败: codegraph --version 执行异常"
        print_recovery_guidance
        return 1
    fi

    ok "CodeGraph verify 通过: $version_output"
}

main() {
    require_supported_platform

    if [[ "$FORCE" == false && "$REFRESH" == false ]] && codegraph_ready; then
        pass "CodeGraph 已就绪，跳过"
        verify
        return 0
    fi

    if [[ "$FORCE" == true || "$REFRESH" == true ]]; then
        info "刷新 CodeGraph 安装..."
    fi

    install
    verify
}

main "$@"
