#!/usr/bin/env bash
# install-ecc.sh — Everything Claude Code 插件安装
set -euo pipefail

REPO_ROOT="${1:?需要 REPO_ROOT}"
DRY_RUN="${2:-false}"
FORCE="${3:-false}"
INSTALL_MODE="${4:-focused}"

ECC_DIR="$REPO_ROOT/external/everything-claude-code"
CUSTOM_AGENTS_DIR="$REPO_ROOT/config/claude/agents-custom"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INSTALL_STATE="$CLAUDE_HOME/ecc/install-state.json"
MARKETPLACE_DST="$CLAUDE_HOME/plugins/marketplaces/ecc"
AGENTS_DST="$CLAUDE_HOME/agents"
COMMANDS_DST="$CLAUDE_HOME/commands"
RULES_DST="$CLAUDE_HOME/rules/ecc"
REQUIRED_CUSTOM_AGENTS=(git.md progress.md rules.md validation.md)
FOCUSED_MODULES=(
    rules-core
    agents-core
    commands-core
    hooks-runtime
    platform-configs
    workflow-quality
    framework-language
    skill-bun-runtime
    skill-cpp-coding-standards
    skill-cpp-testing
    skill-java-coding-standards
    skill-nodejs-keccak256
    skill-ui-to-vue
    skill-vite-patterns
)
OPTIONAL_ECC_INSTALLS=(
    "--ecc-full: 安装 ECC full profile"
    "./external/everything-claude-code/install.sh --target claude --profile <name>: minimal/core/developer/security/research/full"
    "./external/everything-claude-code/install.sh --target claude --modules <id,id,...>: 安装指定 ECC 模块"
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

custom_agents_ready() {
    local name
    [[ -d "$CUSTOM_AGENTS_DIR" ]] || return 0
    for name in "${REQUIRED_CUSTOM_AGENTS[@]}"; do
        [[ -f "$AGENTS_DST/$name" ]] || return 1
        [[ ! -L "$AGENTS_DST/$name" ]] || return 1
    done
    return 0
}

expected_request_ready() {
    [[ -f "$INSTALL_STATE" ]] || return 1
    INSTALL_MODE="$INSTALL_MODE" FOCUSED_MODULES_CSV="$(IFS=,; printf '%s' "${FOCUSED_MODULES[*]}")" python3 - "$INSTALL_STATE" <<'PYEOF'
import json
import os
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    state = json.load(fh)
request = state.get('request', {}) if isinstance(state, dict) else {}
mode = os.environ['INSTALL_MODE']
if mode == 'full':
    sys.exit(0 if request.get('profile') == 'full' else 1)
expected = [item for item in os.environ['FOCUSED_MODULES_CSV'].split(',') if item]
actual = request.get('modules') if isinstance(request.get('modules'), list) else []
sys.exit(0 if sorted(actual) == sorted(expected) else 1)
PYEOF
}

print_install_scope() {
    if [[ "$INSTALL_MODE" == "full" ]]; then
        info "ECC 安装范围: full profile (CI/显式 --ecc-full)"
        return 0
    fi

    info "ECC 默认安装范围: C/C++、Java、JavaScript/TypeScript、Vue 常用能力"
    info "ECC 默认模块: $(IFS=,; printf '%s' "${FOCUSED_MODULES[*]}")"
    info "ECC 可选安装: ${OPTIONAL_ECC_INSTALLS[*]}"
}

is_ready() {
    [[ -d "$ECC_DIR/node_modules" ]] || return 1
    [[ -f "$INSTALL_STATE" ]] || return 1
    expected_request_ready || return 1
    symlink_points_to "$MARKETPLACE_DST" "$ECC_DIR" || return 1
    [[ -d "$AGENTS_DST" ]] || return 1
    [[ -d "$COMMANDS_DST" ]] || return 1
    [[ -d "$RULES_DST" ]] || return 1
    custom_agents_ready || return 1
}

remove_legacy_links() {
    local path
    for path in "$AGENTS_DST" "$COMMANDS_DST"; do
        [[ -L "$path" ]] || continue
        rm -f "$path"
        info "移除旧符号链接: $path"
    done
}

link_marketplace() {
    if symlink_points_to "$MARKETPLACE_DST" "$ECC_DIR"; then
        ok "ECC marketplace 已注册"
        return 0
    fi

    mkdir -p "$(dirname "$MARKETPLACE_DST")"
    if [[ -L "$MARKETPLACE_DST" || -f "$MARKETPLACE_DST" ]]; then
        rm -f "$MARKETPLACE_DST"
    elif [[ -d "$MARKETPLACE_DST" ]]; then
        rm -rf "$MARKETPLACE_DST"
    fi
    ln -sfn "$ECC_DIR" "$MARKETPLACE_DST"
    ok "ECC marketplace 已注册"
}

overlay_custom_agents() {
    [[ -d "$CUSTOM_AGENTS_DIR" ]] || {
        ok "无自定义 agents 覆盖"
        return 0
    }

    mkdir -p "$AGENTS_DST"
    local source_file name
    shopt -s nullglob
    for source_file in "$CUSTOM_AGENTS_DIR"/*.md; do
        name="$(basename "$source_file")"
        cp "$source_file" "$AGENTS_DST/$name"
        ok "自定义 agent 已覆盖: $name"
    done
    shopt -u nullglob
}

install() {
    if [[ ! -d "$ECC_DIR/node_modules" ]]; then
        info "npm install ECC..."
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] (cd $ECC_DIR && npm install --no-audit --no-fund --loglevel=error)"
        else
            (
                cd "$ECC_DIR"
                npm install --no-audit --no-fund --loglevel=error
            )
            ok "ECC node_modules 已安装"
        fi
    else
        ok "ECC node_modules 已存在"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_install_scope
        info "[DRY-RUN] 移除旧 agents/commands 符号链接"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            info "[DRY-RUN] (cd $ECC_DIR && ./install.sh --profile full --target claude)"
        else
            info "[DRY-RUN] (cd $ECC_DIR && ./install.sh --target claude --modules $(IFS=,; printf '%s' "${FOCUSED_MODULES[*]}"))"
        fi
        info "[DRY-RUN] ln -sfn $ECC_DIR -> $MARKETPLACE_DST"
        info "[DRY-RUN] cp $CUSTOM_AGENTS_DIR/*.md -> $AGENTS_DST/"
        return 0
    fi

    remove_legacy_links
    print_install_scope
    info "运行 ECC 官方安装器..."
    (
        cd "$ECC_DIR"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            ./install.sh --profile full --target claude > /dev/null 2>&1
        else
            ./install.sh --target claude --modules "$(IFS=,; printf '%s' "${FOCUSED_MODULES[*]}")" > /dev/null 2>&1
        fi
    )
    ok "ECC 官方安装完成"
    link_marketplace
    overlay_custom_agents
}

verify() {
    if [[ "$DRY_RUN" == true ]]; then
        info "dry-run 模式跳过 verify"
        return 0
    fi

    [[ -d "$ECC_DIR/node_modules" ]] || { err "ECC node_modules 不存在"; return 1; }
    [[ -f "$INSTALL_STATE" ]] || { err "ECC install-state 不存在"; return 1; }
    expected_request_ready || { err "ECC install-state 与期望安装范围不一致"; return 1; }
    symlink_points_to "$MARKETPLACE_DST" "$ECC_DIR" || { err "ECC marketplace 未指向源码目录"; return 1; }
    [[ -d "$AGENTS_DST" ]] || { err "ECC agents 目录不存在"; return 1; }
    [[ ! -L "$AGENTS_DST" ]] || { err "ECC agents 不应为符号链接"; return 1; }
    [[ -d "$COMMANDS_DST" ]] || { err "ECC commands 目录不存在"; return 1; }
    [[ ! -L "$COMMANDS_DST" ]] || { err "ECC commands 不应为符号链接"; return 1; }
    [[ -d "$RULES_DST" ]] || { err "ECC rules 目录不存在"; return 1; }
    custom_agents_ready || { err "自定义 agents 覆盖不完整"; return 1; }

    ok "ECC verify 通过"
}

main() {
    if [[ "$FORCE" == false ]] && is_ready; then
        pass "ECC 已就绪，跳过"
        verify
        return 0
    fi

    install
    verify
}

main "$@"
