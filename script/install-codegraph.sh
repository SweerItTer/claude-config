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
CODEGRAPH_CLAUDE_CONFIG_PATH="$HOME/.claude.json"
CODEGRAPH_CLAUDE_DISCOVERY_COMMAND="claude mcp get codegraph"
CODEGRAPH_CLAUDE_INSTALL_COMMAND="codegraph install -t claude -y"

pass() { echo "  [PASS] $*"; }
info() { echo "  [INFO] $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [ERR] $*"; }

VERIFICATION_INSTALL_STATUS="pending"
VERIFICATION_INSTALL_DETAIL=""
VERIFICATION_CONFIGURE_STATUS="pending"
VERIFICATION_CONFIGURE_DETAIL=""
VERIFICATION_OFFLINE_STATUS="pending"
VERIFICATION_OFFLINE_DETAIL=""
VERIFICATION_OVERALL_STATUS="pending"
VERIFICATION_OVERALL_DETAIL=""

print_recovery_guidance() {
    info "可手动重试官方安装器: $CODEGRAPH_UPSTREAM_COMMAND"
    info "若官方安装器失败且 npm 可用，可改用 fallback: $CODEGRAPH_FALLBACK_COMMAND"
}

print_claude_integration_guidance() {
    info "可手动重新写入 Claude MCP 配置: $CODEGRAPH_CLAUDE_INSTALL_COMMAND"
    info "可手动检查 CodeGraph MCP 详情: $CODEGRAPH_CLAUDE_DISCOVERY_COMMAND"
    info "可列出当前 Claude MCP 列表: claude mcp list"
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

ensure_codegraph_path() {
    local user_bin="$HOME/.local/bin"
    [[ -d "$user_bin" ]] || return 0

    case ":$PATH:" in
        *":$user_bin:"*) ;;
        *) export PATH="$user_bin:$PATH" ;;
    esac
}

codegraph_ready() {
    ensure_codegraph_path
    command -v codegraph >/dev/null 2>&1 || return 1
    codegraph --version >/dev/null 2>&1
}

reset_verification_results() {
    VERIFICATION_INSTALL_STATUS="pending"
    VERIFICATION_INSTALL_DETAIL=""
    VERIFICATION_CONFIGURE_STATUS="pending"
    VERIFICATION_CONFIGURE_DETAIL=""
    VERIFICATION_OFFLINE_STATUS="pending"
    VERIFICATION_OFFLINE_DETAIL=""
    VERIFICATION_OVERALL_STATUS="pending"
    VERIFICATION_OVERALL_DETAIL=""
}

set_layer_result() {
    local layer="$1"
    local status="$2"
    local detail="${3:-}"

    case "$layer" in
        install)
            VERIFICATION_INSTALL_STATUS="$status"
            VERIFICATION_INSTALL_DETAIL="$detail"
            ;;
        configure)
            VERIFICATION_CONFIGURE_STATUS="$status"
            VERIFICATION_CONFIGURE_DETAIL="$detail"
            ;;
        offline_verify)
            VERIFICATION_OFFLINE_STATUS="$status"
            VERIFICATION_OFFLINE_DETAIL="$detail"
            ;;
        overall)
            VERIFICATION_OVERALL_STATUS="$status"
            VERIFICATION_OVERALL_DETAIL="$detail"
            ;;
    esac
}

first_non_empty_line() {
    local text="${1:-}"
    local line

    while IFS= read -r line; do
        if [[ -n "${line//[[:space:]]/}" ]]; then
            printf '%s' "$line"
            return 0
        fi
    done <<< "$text"

    return 1
}

mark_pending_layers_skipped() {
    local reason="$1"

    if [[ "$VERIFICATION_CONFIGURE_STATUS" == "pending" ]]; then
        set_layer_result configure skipped "$reason"
    fi

    if [[ "$VERIFICATION_OFFLINE_STATUS" == "pending" ]]; then
        set_layer_result offline_verify skipped "$reason"
    fi
}

print_layer_result() {
    local layer="$1"
    local status="$2"
    local detail="$3"
    local label

    case "$layer" in
        install) label="install" ;;
        configure) label="configure" ;;
        offline_verify) label="offline_verify" ;;
        overall) label="overall" ;;
        *) label="$layer" ;;
    esac

    case "$status" in
        success)
            ok "CodeGraph ${label} 通过: $detail"
            ;;
        warning)
            warn "CodeGraph ${label}: $detail"
            ;;
        failure)
            err "CodeGraph ${label} 失败: $detail"
            ;;
        skipped)
            info "CodeGraph ${label} 跳过: $detail"
            ;;
        *)
            info "CodeGraph ${label}: $detail"
            ;;
    esac
}

print_verification_summary() {
    print_layer_result install "$VERIFICATION_INSTALL_STATUS" "$VERIFICATION_INSTALL_DETAIL"
    print_layer_result configure "$VERIFICATION_CONFIGURE_STATUS" "$VERIFICATION_CONFIGURE_DETAIL"
    print_layer_result offline_verify "$VERIFICATION_OFFLINE_STATUS" "$VERIFICATION_OFFLINE_DETAIL"
    print_layer_result overall "$VERIFICATION_OVERALL_STATUS" "$VERIFICATION_OVERALL_DETAIL"
}

install_with_upstream() {
    info "优先使用 CodeGraph 官方安装器..."
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $CODEGRAPH_UPSTREAM_COMMAND"
        info "[DRY-RUN] 若官方安装器失败且 npm 可用，将执行 fallback: $CODEGRAPH_FALLBACK_COMMAND"
        return 0
    fi

    if curl -fsSL "$CODEGRAPH_INSTALLER_URL" | sh; then
        ensure_codegraph_path
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
    ensure_codegraph_path
    ok "CodeGraph 已通过 npm fallback 安装"
    info "如需恢复到官方安装路径，请在网络恢复后重新运行: $CODEGRAPH_UPSTREAM_COMMAND"
}

install_claude_integration() {
    ensure_codegraph_path

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] $CODEGRAPH_CLAUDE_INSTALL_COMMAND"
        return 0
    fi

    if ! codegraph install -t claude -y; then
        err "CodeGraph Claude MCP 配置写入失败"
        print_claude_integration_guidance
        return 1
    fi

    if ! check_claude_config >/dev/null 2>&1; then
        err "CodeGraph Claude MCP 配置写入后校验失败"
        print_claude_integration_guidance
        return 1
    fi

    ok "CodeGraph Claude MCP 配置写入完成"
    return 0
}

install() {
    require_supported_platform

    if install_with_upstream; then
        install_claude_integration
        return $?
    fi

    if install_with_npm_fallback; then
        install_claude_integration
        return $?
    fi

    return 1
}

verify_install_layer() {
    ensure_codegraph_path

    if ! command -v codegraph >/dev/null 2>&1; then
        set_layer_result install failure "未找到 codegraph 命令"
        mark_pending_layers_skipped "install 未通过，跳过后续检查"
        return 1
    fi

    local version_output
    if ! version_output="$(codegraph --version 2>&1)"; then
        set_layer_result install failure "codegraph --version 执行异常"
        mark_pending_layers_skipped "install 未通过，跳过后续检查"
        return 1
    fi

    set_layer_result install success "$version_output"
    return 0
}

check_claude_config() {
    CODEGRAPH_CONFIG_PATH="$CODEGRAPH_CLAUDE_CONFIG_PATH" python3 - <<'PY'
import json
import os
import sys

path = os.environ['CODEGRAPH_CONFIG_PATH']

try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except FileNotFoundError:
    print(f'{path} 不存在')
    sys.exit(1)
except json.JSONDecodeError as exc:
    print(f'{path} 不是有效 JSON: {exc}')
    sys.exit(1)

mcp_servers = data.get('mcpServers')
if not isinstance(mcp_servers, dict):
    print(f'{path} 缺少 mcpServers 对象')
    sys.exit(1)

codegraph = mcp_servers.get('codegraph')
if not isinstance(codegraph, dict):
    print(f'{path} 缺少 mcpServers.codegraph 配置')
    sys.exit(1)

problems = []
if codegraph.get('command') != 'codegraph':
    problems.append(f'command={codegraph.get("command")!r}')
if codegraph.get('args') != ['serve', '--mcp']:
    problems.append(f'args={codegraph.get("args")!r}')
if codegraph.get('type') != 'stdio':
    problems.append(f'type={codegraph.get("type")!r}')

if problems:
    print(f'{path} 中 codegraph MCP 配置不符合预期: ' + '; '.join(problems))
    sys.exit(1)

print(f'{path} 已包含期望的 mcpServers.codegraph 配置')
PY
}

repair_claude_integration_if_needed() {
    if check_claude_config >/dev/null 2>&1; then
        return 0
    fi

    info "检测到 Claude MCP 配置缺失或不匹配，重新写入..."
    install_claude_integration
}

verify_configure_layer() {
    local configure_detail

    if ! configure_detail="$(check_claude_config)"; then
        set_layer_result configure failure "$configure_detail"
        set_layer_result offline_verify skipped "configure 未通过，跳过离线发现检查"
        return 1
    fi

    set_layer_result configure success "$configure_detail"
    return 0
}

verify_offline_layer() {
    if ! command -v claude >/dev/null 2>&1; then
        set_layer_result offline_verify failure "未找到 claude 命令，无法执行离线 MCP 检查"
        return 1
    fi

    local offline_output rc first_line
    set +e
    offline_output="$(claude mcp get codegraph 2>&1)"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        first_line="$(first_non_empty_line "$offline_output" || true)"
        set_layer_result offline_verify failure "claude mcp get codegraph 执行失败${first_line:+: $first_line}"
        return 1
    fi

    if [[ "$offline_output" != *"Command: codegraph"* ]]; then
        set_layer_result offline_verify failure "claude mcp get codegraph 未显示 Command: codegraph"
        return 1
    fi

    if [[ "$offline_output" != *"Args: serve --mcp"* ]]; then
        set_layer_result offline_verify failure "claude mcp get codegraph 未显示 Args: serve --mcp"
        return 1
    fi

    if [[ "$offline_output" != *"Status: ✓ Connected"* ]]; then
        if [[ "$offline_output" == *"Status:"* ]]; then
            set_layer_result offline_verify failure "claude 已发现 codegraph，但未显示 ✓ Connected"
        else
            set_layer_result offline_verify failure "claude mcp get codegraph 未显示连接状态"
        fi
        return 1
    fi

    set_layer_result offline_verify success "claude mcp get codegraph 显示 ✓ Connected"
    return 0
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    reset_verification_results

    if ! verify_install_layer; then
        set_layer_result overall failure "CLI 未就绪，无法继续 Claude 集成校验"
        print_verification_summary
        print_recovery_guidance
        return 1
    fi

    if ! verify_configure_layer; then
        set_layer_result overall failure "Claude MCP 配置未通过"
        print_verification_summary
        print_claude_integration_guidance
        return 1
    fi

    if ! verify_offline_layer; then
        set_layer_result overall warning "CLI 与配置已通过，但离线发现失败"
        print_verification_summary
        print_claude_integration_guidance
        return 0
    fi

    set_layer_result overall success "CLI、配置与离线发现均通过"
    print_verification_summary
    return 0
}

main() {
    require_supported_platform

    if [[ "$FORCE" == false && "$REFRESH" == false ]] && codegraph_ready; then
        pass "CodeGraph 已就绪，跳过"
        repair_claude_integration_if_needed || return $?
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
