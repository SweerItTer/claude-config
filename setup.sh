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
            echo ""
            echo "一键初始化 Claude Code 配置环境。"
            echo "符号链接所有配置、注册 marketplace、安装 RTK。"
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
    command -v curl   >/dev/null 2>&1 || missing+=(curl)
    command -v tar    >/dev/null 2>&1 || missing+=(tar)

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少依赖: ${missing[*]}"
        exit 1
    fi
    log "所有依赖已满足"
}

# --------------- 符号链接辅助 ---------------
link_file() {
    local src="$1" dst="$2"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] ln -sf $src -> $dst"; return; }
    mkdir -p "$(dirname "$dst")"
    [[ -L "$dst" ]] || [[ -f "$dst" ]] && rm -f "$dst"
    ln -s "$src" "$dst"
}

link_dir() {
    local src="$1" dst="$2"
    [[ "$DRY_RUN" == true ]] && { info "[DRY-RUN] ln -sfn $src -> $dst"; return; }
    mkdir -p "$(dirname "$dst")"
    [[ -L "$dst" ]] || [[ -d "$dst" ]] && rm -rf "$dst"
    ln -sfn "$src" "$dst"
}

# --------------- Submodule 初始化 ---------------
init_submodules() {
    info "初始化 git submodules..."
    [[ "$DRY_RUN" == false ]] && { cd "$REPO_ROOT" && git submodule update --init --recursive; }
    log "Submodules 就绪"
}

# --------------- Claude 核心配置 ---------------
setup_claude_core() {
    info "链接 Claude Code 核心配置..."
    local cfg="$REPO_ROOT/config/claude"
    local target="$HOME/.claude"

    link_file "$cfg/CLAUDE.md"  "$target/CLAUDE.md"
    link_file "$cfg/RTK.md"     "$target/RTK.md"
    link_file "$cfg/AGENTS.md"  "$target/AGENTS.md"
    link_dir  "$cfg/rules"      "$target/rules"

    # 复制 settings 模板 (仅当 settings.json 不存在时)
    if [[ ! -f "$target/settings.json" ]] && [[ -f "$cfg/settings.template.json" ]]; then
        [[ "$DRY_RUN" == false ]] && cp "$cfg/settings.template.json" "$target/settings.json"
        [[ "$DRY_RUN" == true ]] && info "[DRY-RUN] cp $cfg/settings.template.json -> $target/settings.json"
        warn "已复制 settings 模板 — 请编辑 ~/.claude/settings.json 填入实际的 env 值"
    fi

    log "核心配置已链接"
}

# --------------- Agents (来自 ECC + 自定义) ---------------
setup_agents() {
    info "设置 Agents..."
    local ecc_agents="$REPO_ROOT/external/everything-claude-code/agents"
    local custom="$REPO_ROOT/config/claude/agents-custom"
    local target="$HOME/.claude/agents"

    # 整个 agents 目录符号链接到 ECC
    link_dir "$ecc_agents" "$target"

    # 覆盖自定义 agent 文件 (ECC 之外的 4 个)
    [[ "$DRY_RUN" == false ]] && {
        for f in "$custom"/*.md; do
            cp "$f" "$target/$(basename "$f")"
        done
    }

    log "Agents 已设置 (ECC + 自定义)"
}

# --------------- Skills (来自 ECC + OMC + superpowers) ---------------
setup_skills() {
    info "设置 Skills..."
    local ecc_skills="$REPO_ROOT/external/everything-claude-code/skills"
    local omc_skills="$REPO_ROOT/external/oh-my-claudecode/skills"
    local super_skills="$REPO_ROOT/config/claude/skills-superpowers"
    local target="$HOME/.claude/skills"

    # 创建真实目录
    [[ "$DRY_RUN" == false ]] && { mkdir -p "$target"; }

    # 1. 符号链接 ECC 的所有 skills
    if [[ -d "$ecc_skills" ]]; then
        for skill_dir in "$ecc_skills"/*/; do
            local name; name="$(basename "$skill_dir")"
            link_dir "$skill_dir" "$target/$name"
        done
    fi

    # 2. 符号链接 OMC 的 omc-reference skill
    if [[ -d "$omc_skills/omc-reference" ]]; then
        link_dir "$omc_skills/omc-reference" "$target/omc-reference"
    fi

    # 3. 复制 superpowers skills (不在 submodule 中，纳入仓库)
    if [[ -d "$super_skills" ]]; then
        for skill_dir in "$super_skills"/*/; do
            local name; name="$(basename "$skill_dir")"
            # superpowers skills 作为目录复制（非符号链接）
            [[ "$DRY_RUN" == false ]] && {
                [[ -d "$target/$name" ]] && rm -rf "$target/$name"
                cp -r "$skill_dir" "$target/$name"
            }
            [[ "$DRY_RUN" == true ]] && info "[DRY-RUN] cp -r $skill_dir -> $target/$name"
        done
    fi

    log "Skills 已设置 (ECC + OMC + superpowers)"
}

# --------------- Commands (来自 ECC) ---------------
setup_commands() {
    info "设置 Commands..."
    local ecc_commands="$REPO_ROOT/external/everything-claude-code/commands"
    local target="$HOME/.claude/commands"

    link_dir "$ecc_commands" "$target"
    log "Commands 已链接 (ECC)"
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

    [[ "$DRY_RUN" == false ]] && {
        mkdir -p "$HOME/.claude/plugins"
        sed "s|REPO_ROOT|$REPO_ROOT|g" "$REPO_ROOT/known_marketplaces.json" \
            > "$HOME/.claude/plugins/known_marketplaces.json"
    }

    log "Marketplace 已注册 (4 个)"
}

# --------------- RTK ---------------
RTK_VERSION="v0.40.0"
RTK_INSTALL_DIR="$HOME/.local/bin"

setup_rtk() {
    info "安装 RTK..."
    local cfg="$REPO_ROOT/config/rtk"
    local target="$HOME/.config/rtk"

    # 安装二进制 (从 GitHub Releases 下载预编译静态二进制)
    if command -v rtk >/dev/null 2>&1; then
        log "RTK 已安装: $(rtk --version 2>&1)"
    else
        info "下载 RTK ${RTK_VERSION} 预编译二进制..."
        [[ "$DRY_RUN" == false ]] && {
            local arch; arch="$(uname -m)"
            local tarball="rtk-${arch}-unknown-linux-gnu.tar.gz"

            # musl (静态链接) 在 x86_64 可用
            [[ "$arch" == "x86_64" ]] && tarball="rtk-x86_64-unknown-linux-musl.tar.gz"

            local url="https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${tarball}"
            local tmpdir; tmpdir="$(mktemp -d)"
            curl --fail -sL "$url" -o "$tmpdir/$tarball" || {
                err "下载 RTK 失败: $url"; exit 1
            }
            tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
            mkdir -p "$RTK_INSTALL_DIR"
            # 查找 rtk 二进制 (可能在子目录中)
            local bin; bin="$(find "$tmpdir" -name rtk -type f | head -1)"
            [[ -n "$bin" ]] || { err "未在压缩包中找到 rtk 二进制"; exit 1; }
            mv "$bin" "$RTK_INSTALL_DIR/rtk"
            chmod +x "$RTK_INSTALL_DIR/rtk"
            rm -rf "$tmpdir"
            log "RTK 安装完成: $(rtk --version 2>&1)"
        }
    fi

    # 配置文件
    link_file "$cfg/config.toml"  "$target/config.toml"
    link_file "$cfg/filters.toml" "$target/filters.toml"

    # 不在此运行 rtk init: RTK.md 已由 setup_claude_core 符号链接,
    # settings.json 由用户自行管理。hooks 需手动注册 (见 finish 消息)。
    log "RTK 配置就绪 (hooks 需手动注册到 settings.json)"
}

# --------------- ECC 依赖 ---------------
setup_ecc_deps() {
    info "安装 ECC 依赖..."
    local ecc_dir="$REPO_ROOT/external/everything-claude-code"

    if [[ ! -d "$ecc_dir/node_modules" ]]; then
        [[ "$DRY_RUN" == false ]] && {
            (cd "$ecc_dir" && npm install --no-audit --no-fund --loglevel=error)
        }
        log "ECC 依赖已安装"
    else
        log "ECC 依赖已存在"
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

    # OMC rules-injector 在新版本 (v4.13+) 的 OMC 中已移除
    local omc_ri="$REPO_ROOT/external/oh-my-claudecode/rules-injector"
    if [[ -d "$omc_ri" ]]; then
        link_dir "$omc_ri" "$target/rules-injector"
    fi

    log "OMC 配置已链接"
}

# --------------- 完成 ---------------
finish() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Claude Code 配置迁移完成!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}下一步 (手动):${NC}"
    echo ""
    echo -e "  1. 放入 ${YELLOW}~/.claude/settings.json${NC} (含 API key 和 hooks)"
    echo -e "  2. 启动一次 ${YELLOW}claude${NC} — 让插件系统发现 marketplace 并完成缓存"
    echo -e "  3. 确认插件已激活: 在 claude 内运行 ${YELLOW}/plugin list${NC}"
    echo ""
    echo -e "${BLUE}Hook 配置参考 (需手动写入 settings.json):${NC}"
    echo ""
    echo -e "  RTK:   运行 ${YELLOW}rtk init --hook-only${NC} 获取 hooks 片段"
    echo -e "  ECC:   hooks 由 Claude Code 插件系统自动注册 (启动 claude 即可)"
    echo -e "  OMC:   hooks 由 Claude Code 插件系统自动注册"
    echo -e "  ctx:   hooks 由 Claude Code 插件系统自动注册"
    echo ""
    echo "验证:"
    echo "  claude --version"
    echo "  rtk --version"
    echo "  ls -la ~/.claude/CLAUDE.md            # 符号链接"
    echo "  ls ~/.claude/agents/                  # ECC agents + 自定义"
    echo "  ls ~/.claude/skills/                  # ECC + OMC + superpowers"
    echo "  ls ~/.claude/commands/                # ECC commands"
    echo "  ls ~/.claude/plugins/marketplaces/    # 4 个 marketplace"
    echo ""
}

# --------------- Main ---------------
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Claude Code Config Migration Setup  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    [[ "$DRY_RUN" == true ]] && warn "DRY-RUN 模式 — 不会实际修改文件"

    check_deps
    init_submodules
    setup_claude_core
    setup_agents
    setup_skills
    setup_commands
    setup_marketplaces
    setup_ecc_deps
    setup_rtk
    setup_omc
    finish
}

main "$@"
