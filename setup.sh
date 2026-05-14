#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Claude Code 配置迁移 — 一键初始化脚本
# 用法: git clone --recurse-submodules <repo-url> && ./setup.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=false

log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

# --------------- 参数解析 ---------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "用法: ./setup.sh [--dry-run]"
            exit 0
            ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# --------------- 前置检查 ---------------
check_deps() {
    info "检查前置依赖..."
    local missing=()

    command -v git    >/dev/null 2>&1 || missing+=(git)
    command -v cargo  >/dev/null 2>&1 || missing+=(cargo)
    command -v claude >/dev/null 2>&1 || missing+=(claude)

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少依赖: ${missing[*]}"
        echo "请先安装后重试。"
        echo "  cargo:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        echo "  claude: https://docs.anthropic.com/en/docs/claude-code/overview"
        exit 1
    fi
    log "所有依赖已满足"
}

# --------------- 符号链接辅助 ---------------
link_file() {
    local src="$1" dst="$2"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sf $src -> $dst"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" ]] || [[ -f "$dst" ]]; then
        rm -f "$dst"
    fi
    ln -s "$src" "$dst"
}

link_dir() {
    local src="$1" dst="$2"
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] ln -sfn $src -> $dst"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" ]] || [[ -d "$dst" ]]; then
        rm -rf "$dst"
    fi
    ln -sfn "$src" "$dst"
}

# --------------- Submodule 初始化 ---------------
init_submodules() {
    info "初始化 git submodules..."
    if [[ "$DRY_RUN" == false ]]; then
        cd "$REPO_ROOT"
        git submodule update --init --recursive
    fi
    log "Submodules 就绪"
}

# --------------- Claude 配置 ---------------
setup_claude() {
    info "配置 Claude Code..."
    local cfg="$REPO_ROOT/config/claude"
    local target="$HOME/.claude"

    # 核心配置文件
    link_file "$cfg/CLAUDE.md"  "$target/CLAUDE.md"
    link_file "$cfg/RTK.md"     "$target/RTK.md"
    link_file "$cfg/AGENTS.md"  "$target/AGENTS.md"

    # Agents
    link_dir  "$cfg/agents"     "$target/agents"

    # Rules
    link_dir  "$cfg/rules"      "$target/rules"

    log "Claude 配置已链接"
}

# --------------- Marketplace 注册 ---------------
setup_marketplaces() {
    info "注册插件市场..."
    local ext="$REPO_ROOT/external"
    local mp_dir="$HOME/.claude/plugins/marketplaces"

    link_dir "$ext/oh-my-claudecode"         "$mp_dir/omc"
    link_dir "$ext/context-mode"              "$mp_dir/context-mode"
    link_dir "$ext/everything-claude-code"    "$mp_dir/everything-claude-code"
    link_dir "$ext/claude-plugins-official"   "$mp_dir/claude-plugins-official"

    # 写入 known_marketplaces.json（替换 REPO_ROOT 为实际路径）
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$HOME/.claude/plugins"
        sed "s|REPO_ROOT|$REPO_ROOT|g" "$REPO_ROOT/known_marketplaces.json" \
            > "$HOME/.claude/plugins/known_marketplaces.json"
    fi

    log "Marketplace 已注册 (4 个)"
}

# --------------- RTK 配置 ---------------
setup_rtk() {
    info "配置 RTK..."
    local cfg="$REPO_ROOT/config/rtk"
    local target="$HOME/.config/rtk"

    link_file "$cfg/config.toml"  "$target/config.toml"
    link_file "$cfg/filters.toml" "$target/filters.toml"

    # 安装 RTK
    if command -v rtk >/dev/null 2>&1; then
        log "RTK 已安装: $(rtk --version 2>&1)"
    else
        info "安装 RTK..."
        if [[ "$DRY_RUN" == false ]]; then
            cargo install rtk
            log "RTK 安装完成: $(rtk --version 2>&1)"
        fi
    fi
}

# --------------- OMC 配置 ---------------
setup_omc() {
    info "配置 OMC..."
    local cfg="$REPO_ROOT/config/omc"
    local target="$HOME/.omc"

    if [[ -d "$cfg/wiki" ]]; then
        link_dir "$cfg/wiki" "$target/wiki"
    fi

    log "OMC 配置已链接"
}

# --------------- 完成提示 ---------------
finish() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Claude Code 配置迁移完成!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "请确保 ${YELLOW}~/.claude/settings.json${NC} 已配置 API key。"
    echo ""
    echo "验证步骤:"
    echo "  1. claude --version"
    echo "  2. rtk --version"
    echo "  3. ls -la ~/.claude/CLAUDE.md   # 应为符号链接"
    echo "  4. ls ~/.claude/plugins/marketplaces/   # 应有 4 个目录"
    echo ""
}

# --------------- Main ---------------
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Claude Code Config Migration Setup  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY-RUN 模式 — 不会实际修改文件"
    fi

    check_deps
    init_submodules
    setup_claude
    setup_marketplaces
    setup_rtk
    setup_omc
    finish
}

main "$@"
